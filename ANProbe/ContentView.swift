import SwiftUI
import Observation
import AccessorySetupKit
import AccessoryNotifications
import CoreBluetooth

/// Companion app for forwarding iOS notifications to a Pebble via Apple's
/// AccessoryNotifications. This app owns only pairing +
/// forwarding authorization (AccessorySetupKit); the notification data path runs
/// in the three app extensions, which talk to the watch over Bluetooth
/// themselves. It is a standalone companion on purpose: an AccessorySetupKit app
/// cannot create a CBPeripheralManager, so anything that needs a phone-side GATT
/// server has to live in a separate app.
@MainActor
@Observable
final class ForwardingModel: NSObject {
    private let session = ASAccessorySession()
    private let center = AccessoryNotificationCenter()
    private let pebbleService = CBUUID(string: "0000FED9-0000-1000-8000-00805F9B34FB")

    private(set) var accessoryName: String?
    private(set) var statusText = "Starting…"
    var isWorking = false

    func start() {
        session.activate(on: .main) { [weak self] event in self?.handle(event) }
    }

    private func handle(_ event: ASAccessoryEvent) {
        switch event.eventType {
        case .activated, .accessoryAdded, .accessoryChanged:
            let accessory = event.accessory ?? session.accessories.first
            accessoryName = accessory?.displayName
            if let accessory { Task { await refreshStatus(accessory) } }
        case .accessoryRemoved:
            accessoryName = nil
            statusText = "No Pebble paired"
        case .pickerDidDismiss:
            isWorking = false
        default:
            break
        }
    }

    /// Present the AccessorySetupKit picker to pair a Pebble.
    func pair() {
        isWorking = true
        let descriptor = ASDiscoveryDescriptor()
        descriptor.bluetoothServiceUUID = pebbleService
        let item = ASPickerDisplayItem(
            name: "Pebble",
            productImage: UIImage(systemName: "applewatch") ?? UIImage(),
            descriptor: descriptor
        )
        session.showPicker(for: [item]) { [weak self] error in
            Task { @MainActor in
                if let error { self?.statusText = "Pairing error: \(error.localizedDescription)" }
                self?.isWorking = false
            }
        }
    }

    /// Ask the person to allow notification forwarding to the paired Pebble.
    func enableForwarding() {
        guard let accessory = session.accessories.first else { return }
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                let decision = try await center.requestForwarding(for: accessory)
                statusText = describe(decision)
            } catch let error as AccessoryError {
                statusText = describe(error)
            } catch {
                statusText = "Error: \(error.localizedDescription)"
            }
        }
    }

    /// Open the system settings for this accessory's notification forwarding.
    func openSettings() {
        guard let accessory = session.accessories.first else { return }
        Task { _ = try? await center.presentSettings(for: accessory) }
    }

    private func refreshStatus(_ accessory: ASAccessory) async {
        do {
            statusText = describe(try await center.forwardingStatus(for: accessory))
        } catch let error as AccessoryError {
            statusText = describe(error)
        } catch {
            statusText = "Error: \(error.localizedDescription)"
        }
    }

    private func describe(_ decision: ForwardingDecision) -> String {
        switch decision {
        case .allow: return "Forwarding: on (all apps)"
        case .limited: return "Forwarding: on (selected apps)"
        default: return "Forwarding: off"
        }
    }

    private func describe(_ error: AccessoryError) -> String {
        switch error {
        case .unsupportedAccessory: return "This Pebble isn’t set up for forwarding yet"
        case .unsupportedPlatform: return "Notification forwarding is unavailable in this region"
        default: return "Unavailable (\(String(describing: error)))"
        }
    }
}

struct ContentView: View {
    @State private var model = ForwardingModel()

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Image(systemName: "applewatch.radiowaves.left.and.right")
                    .font(.system(size: 56))
                    .foregroundStyle(.tint)
                    .padding(.top, 32)

                VStack(spacing: 6) {
                    Text(model.accessoryName ?? "No Pebble paired")
                        .font(.headline)
                    Text(model.statusText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                VStack(spacing: 12) {
                    if model.accessoryName == nil {
                        Button("Pair a Pebble") { model.pair() }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.isWorking)
                    } else {
                        Button("Enable Notification Forwarding") { model.enableForwarding() }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.isWorking)
                        Button("Forwarding Settings") { model.openSettings() }
                            .buttonStyle(.bordered)
                    }
                }

                Spacer()
            }
            .padding()
            .navigationTitle("Pebble Notifications")
        }
        .onAppear { model.start() }
    }
}

#Preview {
    ContentView()
}
