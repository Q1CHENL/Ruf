// SkyLight's dictionaries hold NSNumber values; Foundation bridges them.
import Foundation

/// The Space layout SkyLight reports per display.
public enum ManagedDisplaySpaces {
    /// Every Space that is not the current one on its display.
    ///
    /// A layout that yields no Space identifiers at all means the keys these
    /// dictionaries are read with have moved, not that the Mac has no Spaces.
    /// Reporting that as "no other Spaces" would let an application whose
    /// windows are elsewhere read as windowless, so it is `nil`, the
    /// unavailable answer. Having Spaces but none of them other than the
    /// current one is the ordinary single-Space Mac.
    public static func otherSpaceIdentifiers(
        in displays: [[String: Any]]
    ) -> [UInt64]? {
        var currentIdentifiers: Set<UInt64> = []
        var allIdentifiers: [UInt64] = []

        for display in displays {
            if let current = display["Current Space"] as? [String: Any],
               let identifier = current["id64"] as? UInt64 {
                currentIdentifiers.insert(identifier)
            }

            for space in display["Spaces"] as? [[String: Any]] ?? [] {
                if let identifier = space["id64"] as? UInt64 {
                    allIdentifiers.append(identifier)
                }
            }
        }

        guard !allIdentifiers.isEmpty else {
            return nil
        }

        return allIdentifiers.filter { !currentIdentifiers.contains($0) }
    }
}
