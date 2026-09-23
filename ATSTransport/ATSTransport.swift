import AccessorySetupKit
@preconcurrency import CoreBluetooth
import AccessoryTransportExtension
import ExtensionFoundation
import Foundation
import OSLog

// AccessoryTransportAppExtension. Apple's design is that the
// transport extension does its own BLE I/O to the accessory — allowed in this
// sandbox once the Info.plist declares NSAccessorySetupKitSupports /
// NSAccessorySetupBluetoothServices / NSAccessorySetupBluetoothNames and the
// CBCentralManager is created with CBCentralManagerOptionDeviceAccessForMedia.
// (Pattern from the public shinvou/NotifBridge demo.) So this writes each sealed
// TransportMessage straight to the watch's RX as a DATA frame; no App Group proxy.
// Subsystem: com.example.anprobe.ANProbe.ATSTransport.

let atxLog = Logger(subsystem: "com.example.anprobe.ANProbe.ATSTransport",
                    category: "transport")

// Watch GATT (Pebble-base-expanded 0x50000000 range) + the FED9 pairing service.
let kService = CBUUID(string: "50000000-328E-0FBB-C642-1AA6699BDADA")
let kRX = CBUUID(string: "50000002-328E-0FBB-C642-1AA6699BDADA")  // phone -> watch (write)
let kTX = CBUUID(string: "50000001-328E-0FBB-C642-1AA6699BDADA")  // watch -> phone (notify)
let kPebbleService = CBUUID(string: "0000FED9-0000-1000-8000-00805F9B34FB")

/// Minimal per-extension BLE writer to the paired Pebble. Connects via
/// CBCentralManager(DeviceAccessForMedia) + ASAccessorySession, writes whole
/// frames (one ATT write each) to RX; optionally subscribes TX and reports the
/// first notification (used by the security extension to read the watch pubkey).
final class PebbleBLE: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate, @unchecked Sendable {
  private let log: Logger
  private let wantTX: Bool
  private var central: CBCentralManager!
  private let ask = ASAccessorySession()
  private var peripheral: CBPeripheral?
  private var rxChar: CBCharacteristic?
  private var queue: [Data] = []
  /// Called with the peripheral's identifier (== iOS's info-string UUID) once known.
  var onConnected: ((UUID) -> Void)?
  /// Called with each TX notification payload (type byte + body).
  var onTXNotify: ((Data) -> Void)?

  init(category: String, wantTX: Bool) {
    self.log = Logger(subsystem: "com.example.anprobe.ANProbe.ATSTransport", category: category)
    self.wantTX = wantTX
    super.init()
    central = CBCentralManager(delegate: self, queue: .main,
                               options: [CBCentralManagerOptionDeviceAccessForMedia: true])
    ask.activate(on: .main) { _ in }
  }

  func write(_ frame: Data) {
    DispatchQueue.main.async { [self] in
      queue.append(frame)
      drain()
    }
  }

  private func drain() {
    guard let p = peripheral, p.state == .connected, let rx = rxChar else { return }
    let items = queue; queue.removeAll()
    for f in items {
      log.log("BLE write \(f.count, privacy: .public) B")
      p.writeValue(f, for: rx, type: .withResponse)
    }
  }

  func centralManagerDidUpdateState(_ central: CBCentralManager) {
    log.log("central state=\(central.state.rawValue, privacy: .public)")
    guard central.state == .poweredOn else { return }
    if let p = central.retrieveConnectedPeripherals(withServices: [kPebbleService]).first {
      connect(p)
    } else {
      central.scanForPeripherals(withServices: [kPebbleService])
    }
  }

  func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral,
                      advertisementData: [String: Any], rssi: NSNumber) {
    c.stopScan(); connect(p)
  }

  private func connect(_ p: CBPeripheral) {
    peripheral = p; p.delegate = self; central.connect(p)
    log.log("connecting to \(p.name ?? "?", privacy: .public)")
  }

  func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
    log.log("✅ connected; discovering service")
    onConnected?(p.identifier)
    p.discoverServices([kService])
  }

  func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
    log.log("disconnected; reconnecting")
    rxChar = nil
    c.connect(p)
  }

  func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
    guard let svc = p.services?.first(where: { $0.uuid == kService }) else {
      log.error("service missing"); return
    }
    p.discoverCharacteristics(wantTX ? [kRX, kTX] : [kRX], for: svc)
  }

  func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor svc: CBService, error: Error?) {
    rxChar = svc.characteristics?.first { $0.uuid == kRX }
    if wantTX, let tx = svc.characteristics?.first(where: { $0.uuid == kTX }) {
      p.setNotifyValue(true, for: tx)
    }
    log.log("chars ready (rx=\(self.rxChar != nil, privacy: .public))")
    drain()
  }

  func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
    if let v = ch.value { onTXNotify?(v) }
  }
}

final class ATSTransportHandler: AccessoryTransportSession.EventHandler {
  let session: AccessoryTransportSession
  init(session: AccessoryTransportSession) { self.session = session }

  func messageReceived(_ message: TransportMessage,
                       completion: @escaping @Sendable (AccessoryMessage.Result) -> Void) {
    let sid = Data(message.sessionID.uuidString.utf8)
    // DATA frame = 0x03 | u8 sid_len | sid | wire(nonce|ct|tag). The wire is
    // already-encrypted notification content — never logged.
    var frame = Data([0x03])
    frame.append(UInt8(sid.count)); frame += sid; frame += message.data
    atxLog.log("forwarding encrypted notification to accessory (\(frame.count, privacy: .public) B)")
    transportBLE.write(frame)
    completion(.success)
  }

  func sessionInvalidated(error: AccessoryTransportSession.Error?) {
    atxLog.log("transport session invalidated: \(String(describing: error), privacy: .public)")
  }
}

// Retained for the extension's lifetime. wantTX so we also receive the watch's
// accessory->host reply frames (0x82) and forward them up to the DataProvider.
let transportBLE = PebbleBLE(category: "transport-ble", wantTX: true)

@main
struct ATSTransportExtension: AccessoryTransportAppExtension {
  init() {}

  func accept(sessionRequest: AccessoryTransportSession.Request)
    -> AccessoryTransportSession.Request.Decision {
    atxLog.log("transport session request; accepting (direct-BLE).")
    let session = sessionRequest.session
    // Watch -> phone reply: 0x82 | u8 sid_len | sid | wire → TransportMessage.
    transportBLE.onTXNotify = { data in
      guard data.first == 0x82, data.count >= 2 else { return }
      let sidLen = Int(data[data.index(data.startIndex, offsetBy: 1)])
      guard data.count >= 2 + sidLen else { return }
      let sidData = data.subdata(in: (data.startIndex + 2)..<(data.startIndex + 2 + sidLen))
      let wire = data.subdata(in: (data.startIndex + 2 + sidLen)..<data.endIndex)
      guard let sidStr = String(data: sidData, encoding: .utf8),
            let sessionID = UUID(uuidString: sidStr) else { return }
      do {
        try session.sendMessageToDataProvider(TransportMessage(sessionID: sessionID, data: wire))
        atxLog.log("forwarded accessory→host reply (\(wire.count, privacy: .public) B) to data provider")
      } catch {
        atxLog.log("sendMessageToDataProvider failed: \(String(describing: error), privacy: .public)")
      }
    }
    return sessionRequest.accept { ATSTransportHandler(session: session) }
  }
}
