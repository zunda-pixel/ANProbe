import AccessoryNotifications
import AccessoryTransportExtension
import ExtensionFoundation
import Foundation
import OSLog
import UserNotifications

// AccessoryDataProvider providing the NotificationsForwarding feature, wired per
// Apple's "Receiving iOS notifications on an accessory" article. Doubles as an
// OBSERVATION INSTRUMENT (#29): logs every handler callback with
// .public so we can see the forwarding lifecycle on the device console
// (subsystem com.example.anprobe.ANProbe.ATSDataProvider).

let adpLog = Logger(subsystem: "com.example.anprobe.ANProbe.ATSDataProvider",
                    category: "dataprovider")

private func hex(_ data: Data) -> String {
  data.map { String(format: "%02x", $0) }.joined()
}

final class NotificationHandler: NotificationsForwarding.AccessoryNotificationsHandler {
  var session: NotificationsForwarding.Session?
  // notificationIdentifier -> sourceIdentifier, so a watch action reply (which
  // carries only the notification + action ids) can be turned into a full
  // NotificationResponse.
  private var sourceByNotifId: [String: String] = [:]

  func didActivate(for session: NotificationsForwarding.Session) {
    self.session = session
    adpLog.log("didActivate: forwarding session established")
  }

  func addNotification(_ notification: AccessoryNotification,
                       alertingContext: AlertingContext) async throws -> Bool {
    // Notification content is the user's private data — never log it in the clear.
    adpLog.log("addNotification: source=\(notification.sourceName, privacy: .private) shouldAlert=\(alertingContext.shouldAlert, privacy: .public)")
    guard let session else { return false }
    sourceByNotifId[notification.identifier.notificationIdentifier] =
      notification.identifier.sourceIdentifier
    let payload = NotificationWire.serialize(notification, alert: alertingContext.shouldAlert)
    let msg = AccessoryMessage {
      AccessoryMessage.Payload(transport: .bluetooth, data: payload)
    }
    do {
      try await session.send(message: msg)
      adpLog.log("forwarded notification (\(payload.count, privacy: .public) B)")
      return true
    } catch {
      adpLog.log("forward failed: \(String(describing: error), privacy: .public)")
      return false
    }
  }

  func updateNotification(_ notification: AccessoryNotification) {
    adpLog.log("updateNotification: source=\(notification.sourceName, privacy: .private)")
    guard let session else { return }
    let payload = NotificationWire.serialize(notification, alert: false)
    let msg = AccessoryMessage { AccessoryMessage.Payload(transport: .bluetooth, data: payload) }
    Task { try? await session.send(message: msg) }
  }

  func removeNotification(identifier: AccessoryNotification.Identifier) {
    adpLog.log("removeNotification")
    guard let session else { return }
    let payload = NotificationWire.removal(identifier.notificationIdentifier)
    let msg = AccessoryMessage { AccessoryMessage.Payload(transport: .bluetooth, data: payload) }
    Task { try? await session.send(message: msg) }
  }

  func removeAllNotifications() {
    adpLog.log("removeAllNotifications")
    guard let session else { return }
    let msg = AccessoryMessage { AccessoryMessage.Payload(transport: .bluetooth, data: NotificationWire.removeAll()) }
    Task { try? await session.send(message: msg) }
  }

  func messageHandler(_ message: TransportMessage) {
    // Accessory→host reply from a watch notification action, decrypted by iOS from
    // the watch's AccessoryToHost seal. Wire =
    //   u8 nid_len | nid | u8 aid_len | aid | u16 text_len (LE) | text
    // text is present (possibly empty) for a text-input action, absent for a plain
    // one; empty or absent means no user text.
    let d = [UInt8](message.data)
    guard d.count >= 2 else { return }
    var o = 0
    let nidLen = Int(d[o]); o += 1
    guard o + nidLen + 1 <= d.count else { return }
    let nid = String(decoding: d[o..<o + nidLen], as: UTF8.self); o += nidLen
    let aidLen = Int(d[o]); o += 1
    guard o + aidLen <= d.count else { return }
    let aid = String(decoding: d[o..<o + aidLen], as: UTF8.self); o += aidLen
    var userText: String? = nil
    if o + 2 <= d.count {
      let textLen = Int(d[o]) | (Int(d[o + 1]) << 8); o += 2
      if textLen > 0, o + textLen <= d.count {
        userText = String(decoding: d[o..<o + textLen], as: UTF8.self)
      }
    }
    let source = sourceByNotifId[nid] ?? ""
    adpLog.log("action reply: notif=\(nid, privacy: .private) action=\(aid, privacy: .public) hasText=\(userText != nil)")
    guard let session else { return }
    let response = NotificationResponse(sourceIdentifier: source, notificationIdentifier: nid,
                                        actionIdentifier: aid, userText: userText)
    Task {
      do { try await session.sendResponse(response); adpLog.log("sendResponse OK") }
      catch { adpLog.log("sendResponse failed: \(String(describing: error), privacy: .public)") }
    }
  }

  func didInvalidate() {
    adpLog.log("didInvalidate")
    session = nil
  }
}

//! The notification wire format sent to the watch (decrypted on the accessory).
//! Compact TLV so the firmware can parse it: [u8 msgType][TLV…].
//!   msgType: 0x01 present/update, 0x02 remove-one, 0x03 remove-all
//!   TLV (present/update): tag(u8) len(u8) value(UTF-8, truncated to 255)
//!     tags: 0x01 title, 0x02 subtitle, 0x03 body, 0x04 source, 0x05 identifier,
//!           0x06 alert(1 byte: 0/1),
//!           0x07 action = [u8 flags | u8 aid_len | aid | u8 title_len | title]
//!             flags bit 0 = text-input action (watch collects reply text)
//!   remove-one payload: the identifier UTF-8 (after the msgType byte).
enum NotificationWire {
  static func serialize(_ n: AccessoryNotification, alert: Bool) -> Data {
    var out = Data([0x01])
    func tlv(_ tag: UInt8, _ s: String?) {
      guard let s, !s.isEmpty else { return }
      let v = Data(s.utf8.prefix(255))
      out.append(tag); out.append(UInt8(v.count)); out += v
    }
    tlv(0x01, n.title)
    tlv(0x02, n.subtitle)
    tlv(0x03, n.body?.string)
    tlv(0x04, n.sourceName)
    tlv(0x05, n.identifier.notificationIdentifier)
    out.append(0x06); out.append(1); out.append(alert ? 1 : 0)
    // Actions (up to 4): the watch shows them and replies with the chosen id. A
    // text-input action gets flag bit 0 set, so the watch collects a reply and
    // sends it back as the response's user text.
    for action in n.actions.prefix(4) {
      let flags: UInt8 = (action is UNTextInputNotificationAction) ? 0x01 : 0x00
      let aid = Data(action.identifier.utf8.prefix(120))
      let title = Data((action.title ?? "").utf8.prefix(120))
      var entry = Data()
      entry.append(flags)
      entry.append(UInt8(aid.count)); entry += aid
      entry.append(UInt8(title.count)); entry += title
      out.append(0x07); out.append(UInt8(entry.count)); out += entry
    }
    return out
  }

  static func removal(_ identifier: String) -> Data {
    Data([0x02]) + Data(identifier.utf8.prefix(255))
  }

  static func removeAll() -> Data { Data([0x03]) }
}

@main
struct ATSDataProviderExtension: AccessoryDataProvider {
  var extensionPoint: AppExtensionPoint {
    Identifier("com.apple.accessory-data-provider")
    Implementing {
      NotificationsForwarding {
        NotificationHandler()
      }
    }
  }
}
