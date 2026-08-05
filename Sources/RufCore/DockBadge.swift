import Foundation

public struct DockBadge: Equatable, Sendable {
    public let displayText: String?
    public let accessibilityLabel: String

    public init?(statusLabel: String?) {
        guard let statusLabel else {
            return nil
        }

        let normalizedLabel = statusLabel.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !normalizedLabel.isEmpty else {
            return nil
        }

        let displayText: String?
        if let count = Int(normalizedLabel), count > 999 {
            displayText = "999+"
        } else if normalizedLabel.count <= 4 {
            displayText = normalizedLabel
        } else {
            displayText = nil
        }

        self.displayText = displayText
        accessibilityLabel = normalizedLabel
    }
}
