import AppKit
import RufCore

extension ApplicationDiscoveryPolicy {
    init(activationPolicy: NSApplication.ActivationPolicy, isCurrentApplication: Bool) {
        if isCurrentApplication {
            self = .excluded
            return
        }

        switch activationPolicy {
        case .regular:
            self = .regular
        case .accessory:
            self = .windowsOnly
        case .prohibited:
            self = .excluded
        @unknown default:
            self = .excluded
        }
    }

    @MainActor
    init(application: NSRunningApplication) {
        self.init(
            activationPolicy: application.activationPolicy,
            isCurrentApplication: application.processIdentifier == ProcessInfo.processInfo.processIdentifier
        )
    }
}
