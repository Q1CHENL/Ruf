import AppKit

@MainActor
enum ApplicationIconResolver {
    private struct CachedDockTileIcon {
        let resourceName: String
        let image: NSImage
    }

    // ChatGPT/Codex coordinates its out-of-process Dock tile plugin through
    // this preference. The plugin and in-bundle resource guards keep this
    // compatibility path inert for ordinary applications.
    private static let dockIconResourceNameKey = "DockIconResourceName"
    private static let dockTilePluginKey = "NSDockTilePlugIn"
    private static var cachedDockTileIcons: [String: CachedDockTileIcon] = [:]

    static func icon(for application: NSRunningApplication) -> NSImage? {
        preferredDockTileIcon(for: application) ?? application.icon
    }

    private static func preferredDockTileIcon(
        for application: NSRunningApplication
    ) -> NSImage? {
        guard
            let bundleIdentifier = application.bundleIdentifier,
            let bundleURL = application.bundleURL,
            let bundle = Bundle(url: bundleURL),
            let dockTilePlugin = bundle.object(
                forInfoDictionaryKey: dockTilePluginKey
            ) as? String,
            !dockTilePlugin.isEmpty
        else {
            return nil
        }

        let applicationID = bundleIdentifier as CFString
        _ = CFPreferencesAppSynchronize(applicationID)

        guard
            let resourceName = CFPreferencesCopyAppValue(
                dockIconResourceNameKey as CFString,
                applicationID
            ) as? String,
            !resourceName.isEmpty,
            !resourceName.contains("/"),
            resourceName != ".",
            resourceName != "..",
            let resourceURL = bundle.resourceURL?.appendingPathComponent(
                resourceName,
                isDirectory: false
            )
        else {
            return nil
        }

        if let cachedIcon = cachedDockTileIcons[bundleIdentifier],
           cachedIcon.resourceName == resourceName {
            return cachedIcon.image
        }

        guard let image = NSImage(contentsOf: resourceURL) else {
            cachedDockTileIcons.removeValue(forKey: bundleIdentifier)
            return nil
        }

        cachedDockTileIcons[bundleIdentifier] = CachedDockTileIcon(
            resourceName: resourceName,
            image: image
        )
        return image
    }
}
