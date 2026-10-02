import AppKit
import RufCore

@MainActor
struct ApplicationItem {
    let application: NSRunningApplication
    let discoveryPolicy: ApplicationDiscoveryPolicy
    let bundleIdentifier: String
    let name: String
    let icon: NSImage
}
