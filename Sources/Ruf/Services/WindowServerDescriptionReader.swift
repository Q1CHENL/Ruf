import CoreGraphics

enum WindowServerDescriptionReader {
    static func descriptions(
        for windowIdentifiers: [CGWindowID]
    ) -> [[String: Any]]? {
        let identifierArray = windowIdentifiers
            .map { UnsafeRawPointer(bitPattern: UInt($0)) }
            .withUnsafeBufferPointer {
                CFArrayCreate(
                    nil,
                    UnsafeMutablePointer(mutating: $0.baseAddress),
                    $0.count,
                    nil
                )
            }

        return CGWindowListCreateDescriptionFromArray(identifierArray)
            as? [[String: Any]]
    }

    /// The frame of the application's frontmost visible window, in
    /// WindowServer's top-left-origin global coordinates.
    static func frontmostWindowFrame(
        ownedBy processIdentifier: pid_t
    ) -> CGRect? {
        // On-screen windows are listed front to back.
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return nil
        }

        for window in windows {
            guard
                window[kCGWindowOwnerPID as String] as? Int
                    == Int(processIdentifier),
                window[kCGWindowLayer as String] as? Int == 0,
                let alpha = window[kCGWindowAlpha as String] as? Double,
                alpha > 0,
                let bounds = window[kCGWindowBounds as String]
                    as? [String: Any],
                let frame = CGRect(
                    dictionaryRepresentation: bounds as CFDictionary
                ),
                !frame.isEmpty
            else {
                continue
            }
            return frame
        }
        return nil
    }
}
