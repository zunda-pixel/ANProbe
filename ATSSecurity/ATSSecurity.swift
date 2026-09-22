import AccessorySetupKit
@preconcurrency import CoreBluetooth
import AccessoryTransportExtension
import Foundation
import OSLog

// AccessoryTransportSecurity (KeyExchange) extension for #29, direct-BLE
// design (per shinvou/NotifBridge): this extension does its own Bluetooth I/O to
// the watch. It reads the WATCH's real P-256 public key over BLE (the watch is the
// HPKE recipient and holds its private key), relays it to iOS as the accessory
// public key, and writes iOS's encapsulatedKey back to the watch as a SESSION
// frame. No fake key, no App Group. Subsystem: com.example.anprobe.ANProbe.ATSSecurity.

let atsLog = Logger(subsystem: "com.example.anprobe.ANProbe.ATSSecurity", category: "handshake")

let kService = CBUUID(string: "50000000-328E-0FBB-C642-1AA6699BDADA")
let kRX = CBUUID(string: "50000002-328E-0FBB-C642-1AA6699BDADA")
let kTX = CBUUID(string: "50000001-328E-0FBB-C642-1AA6699BDADA")
let kPebbleService = CBUUID(string: "0000FED9-0000-1000-8000-00805F9B34FB")

/// Per-extension BLE writer/reader to the paired Pebble (see ATSTransport for the
/// twin). Reads the watch pubkey (TX 0x01) and writes SESSION frames (RX).
final class PebbleBLE: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate, @unchecked Sendable {
  private var central: CBCentralManager!
  private let ask = ASAccessorySession()
  private var peripheral: CBPeripheral?
  private var rxChar: CBCharacteristic?
  private var queue: [Data] = []
  var onConnected: ((UUID) -> Void)?
  var onTXNotify: ((Data) -> Void)?

  override init() {
    super.init()
    central = CBCentralManager(delegate: self, queue: .main,
                               options: [CBCentralManagerOptionDeviceAccessForMedia: true])
    ask.activate(on: .main) { _ in }
  }

  func write(_ frame: Data) {
    DispatchQueue.main.async { [self] in queue.append(frame); drain() }
  }

  private func drain() {
    guard let p = peripheral, p.state == .connected, let rx = rxChar else { return }
    let items = queue; queue.removeAll()
    for f in items {
      atsLog.log("BLE write \(f.count, privacy: .public) B")
      p.writeValue(f, for: rx, type: .withResponse)
    }
  }

  func centralManagerDidUpdateState(_ central: CBCentralManager) {
    atsLog.log("central state=\(central.state.rawValue, privacy: .public)")
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
    atsLog.log("connecting to \(p.name ?? "?", privacy: .public)")
  }

  func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
    atsLog.log("✅ connected; discovering service")
    onConnected?(p.identifier)
    p.discoverServices([kService])
  }

  func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
    atsLog.log("disconnected; reconnecting")
    rxChar = nil
    c.connect(p)
  }

  func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
    guard let svc = p.services?.first(where: { $0.uuid == kService }) else {
      atsLog.error("service missing"); return
    }
    p.discoverCharacteristics([kRX, kTX], for: svc)
  }

  func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor svc: CBService, error: Error?) {
    rxChar = svc.characteristics?.first { $0.uuid == kRX }
    if let tx = svc.characteristics?.first(where: { $0.uuid == kTX }) {
      p.setNotifyValue(true, for: tx)
    }
    atsLog.log("chars ready (rx=\(self.rxChar != nil, privacy: .public))")
    drain()
  }

  func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
    if let v = ch.value { onTXNotify?(v) }
  }
}

final class ATSSecurityHandler: AccessorySecuritySession.EventHandler {
  let session: AccessorySecuritySession
  let ble = PebbleBLE()
  private var accessoryUUID: String?
  private var sentPublicKey = false

  init(session: AccessorySecuritySession) {
    self.session = session
    ble.onConnected = { [weak self] uuid in
      self?.accessoryUUID = uuid.uuidString.uppercased()
      atsLog.log("accessory connected")
    }
    ble.onTXNotify = { [weak self] data in
      guard let self, !self.sentPublicKey, data.first == 0x01, data.count == 65 else { return }
      let pub = data.subdata(in: 1..<65)  // 64-byte raw X||Y (the accessory's public key)
      self.sentPublicKey = true
      let msg = SecurityMessage(keyType: .publicKey, cipherSuite: .p256, version: .version1,
                                key: pub, supportedTransports: [.bluetooth])
      do { try self.session.sendSecurityMessage(msg); atsLog.log("relayed accessory public key to system") }
      catch { atsLog.log("sendSecurityMessage failed: \(String(describing: error), privacy: .public)") }
    }
  }

  func messageReceived(_ message: SecurityMessage,
                       completion: @escaping @Sendable (AccessoryMessage.Result) -> Void) {
    if message.keyType == .encapsulatedKey {
      guard let uuid = accessoryUUID else {
        atsLog.error("enc arrived before accessory connected")
        completion(.failure(.transportFailed)); return
      }
      // SESSION frame = 0x02 | enc(65) | u8 uuid_len | uuid
      let uuidBytes = Data(uuid.utf8)
      var frame = Data([0x02])
      frame += message.key
      frame.append(UInt8(uuidBytes.count)); frame += uuidBytes
      ble.write(frame)
      atsLog.log("forwarded encapsulated key to accessory")
    }
    completion(.success)
  }

  func sessionInvalidated(error: AccessorySecuritySession.Error?) {
    atsLog.log("security session invalidated: \(String(describing: error), privacy: .public)")
  }
}

@main
struct ATSSecurityExtension: AccessoryTransportSecurity {
  init() {}

  func accept(sessionRequest: AccessorySecuritySession.Request)
    -> AccessorySecuritySession.Request.Decision {
    atsLog.log("security session request; accepting (direct-BLE relay of watch key)")
    return sessionRequest.accept { ATSSecurityHandler(session: sessionRequest.session) }
  }
}
