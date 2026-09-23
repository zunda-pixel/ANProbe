// This file previously held bring-up/verification tools used to prove the
// AccessoryNotifications watch path end-to-end:
//   • GattProbeModel — a raw-GATT client that connected to the watch's
//     0x50000000 transport service to Verify / Relay / Listen for the decrypt
//     echo. The production data path runs entirely in the app extensions
//     (ATSSecurity / ATSTransport), so the app no longer needs its own client.
//   • PeripheralTestModel — an experiment that confirmed creating a
//     CBPeripheralManager in an AccessorySetupKit app hard-aborts.
//
// Both were removed for the production companion app. Intentionally left empty
// to avoid a project-file edit.
