import AppKit
import RufCore

@MainActor
struct ApplicationItem {
    let application: NSRunningApplication
    /// Shared by every instance of the application, which the switcher groups
    /// and orders by.
    let applicationIdentifier: String
    let name: String
    let icon: NSImage
}

extension NSRunningApplication {
    /// The bundle identifier, or for a process without one, such as a
    /// `java -jar` application or a Wine program, its executable's path.
    var applicationIdentifier: String? {
        bundleIdentifier ?? executableURL?.path(percentEncoded: false)
    }
}
