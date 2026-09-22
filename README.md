# ANProbe

An iOS companion app used to bring up and verify the **accessory (watch) side of
Apple's [AccessoryNotifications](https://developer.apple.com/documentation/accessorynotifications)**
against a Pebble Time 2 running AccessoryNotifications-enabled firmware.

Apple's AccessoryNotifications lets an iOS app forward the user's notifications to
a Bluetooth accessory over an end-to-end encrypted (HPKE / RFC 9180) channel,
without the accessory needing ANCS. The framework does the encryption inside
ExtensionKit extensions; the transport between phone and accessory is
developer-defined. This app implements that phone side so the watch firmware can
be exercised with real iOS notifications.

## What it does

- Pairs the watch through **AccessorySetupKit** and calls
  `AccessoryNotifications.requestForwarding(for:)` to turn forwarding on.
- Hosts the three ExtensionKit extensions that Apple's design requires, each doing
  its own BLE to the watch's GATT transport service (`0x50000000`):
  - **ATSSecurity** (`com.apple.accessory-transport-security`) — the HPKE key
    exchange: relays the encapsulated key to the watch and the watch's public key
    back.
  - **ATSTransport** (`com.apple.accessory-transport-extension`) — the encrypted
    notification data path in both directions.
  - **ATSDataProvider** (`com.apple.accessory-data-provider`) — serializes each
    notification into the wire format the watch decodes, and observes the reverse
    (action-response) callbacks.

## Requirements

- Xcode with the iOS 26 SDK (AccessoryNotifications / AccessorySetupKit).
- An iPhone with the AccessoryNotifications entitlements provisioned for your
  team. `DEVELOPMENT_TEAM` is left blank and the bundle identifiers use the
  `com.example.anprobe.*` placeholder — set your own team and bundle IDs before
  building.
- A Pebble Time 2 flashed with AccessoryNotifications-capable firmware (the watch
  side that hosts the `0x50000000` transport service and the HPKE layer).

## Status

This is a research / verification instrument, not a shipping product. It proved
the path end-to-end on real hardware: an iPhone notification appears on the watch,
and dismissing it on the iPhone removes it from the watch. The on-watch action
menu (reply) is still under investigation and is gated off in the firmware.
