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
}
