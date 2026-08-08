import AppKit
import CoreGraphics
import Darwin

// Accessibility reports an empty window list for every application whose
// windows live on another Space, and the on-screen WindowServer list only ever
// covers the current one. Neither source can tell "this application has no
// windows" apart from "its windows are on a Space you are not looking at", so
// an application that is merely elsewhere reads as windowless and is offered a
// reopen badge that would strand the user's real window.
//
// The WindowServer's own Space bookkeeping can tell them apart, and nothing
// public can. Only the Spaces that are *not* current are queried: Accessibility
// already sees the current Space, and it sees it more accurately, since a
// window the WindowServer still lists after its application let go of it is
// exactly the kind of ghost the reopen badge should ignore. Each source is
// therefore asked only about the windows it is authoritative for.
enum OtherSpaceWindowResolver {
    private typealias MainConnectionIDFunction = @convention(c) () -> UInt32
    private typealias CopyManagedDisplaySpacesFunction = @convention(c) (
        UInt32
    ) -> Unmanaged<CFArray>?
    private typealias CopyWindowsFunction = @convention(c) (
        UInt32,
        Int,
        CFArray,
        Int,
        UnsafeMutablePointer<Int>,
        UnsafeMutablePointer<Int>
    ) -> Unmanaged<CFArray>?

    private struct Entrypoints {
        let mainConnectionID: MainConnectionIDFunction
        let copyManagedDisplaySpaces: CopyManagedDisplaySpacesFunction
        let copyWindows: CopyWindowsFunction
    }

    // Requesting the invisible tags as well would pull in ordered-out windows:
    // a hidden application's windows, and the alpha=0 and `orderOut:` windows
    // Electron applications leave behind. Those are not reachable targets, and
    // counting them would suppress the badge for an application that really has
    // nothing to switch to.
    //
    // This leaves one known gap: minimized windows on another Space are absent
    // here and from Accessibility, so an application with only such a window can
    // still look windowless. Covering it safely requires window-level state that
    // distinguishes minimized targets from stale or phantom windows; reducing
    // this result to owner PIDs cannot make that decision.
    private static let windowOptions = 0x2

    // Resolved at runtime for the same reason as `_AXUIElementGetWindow`: these
    // are private SkyLight entry points, so their removal has to degrade to the
    // previous, Space-blind behaviour rather than stop Ruf from launching.
    private static let entrypoints: Entrypoints? = {
        guard
            let handle = dlopen(
                "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
                RTLD_LAZY
            ),
            let connection = dlsym(handle, "CGSMainConnectionID"),
            let spaces = dlsym(handle, "CGSCopyManagedDisplaySpaces"),
            let windows = dlsym(handle, "CGSCopyWindowsWithOptionsAndTags")
        else {
            return nil
        }

        return Entrypoints(
            mainConnectionID: unsafeBitCast(
                connection,
                to: MainConnectionIDFunction.self
            ),
            copyManagedDisplaySpaces: unsafeBitCast(
                spaces,
                to: CopyManagedDisplaySpacesFunction.self
            ),
            copyWindows: unsafeBitCast(windows, to: CopyWindowsFunction.self)
        )
    }()

    // Applications owning a window on a Space that is not currently displayed.
    // `nil` means the question could not be asked at all, which callers read as
    // "no additional information" rather than as an empty answer.
    static func processIdentifiersWithWindows() -> Set<pid_t>? {
        guard let entrypoints else {
            return nil
        }

        let connection = entrypoints.mainConnectionID()
        guard let displays = entrypoints.copyManagedDisplaySpaces(connection)?
            .takeRetainedValue() as? [NSDictionary] else {
            return nil
        }

        // A display layout that yields no Space identifiers at all means the
        // keys these dictionaries are read with have moved, not that the Mac
        // has no Spaces. Reporting that as "no other-Space windows" would
        // silently restore the bug this exists to fix, so it degrades to the
        // unavailable answer instead. Having Spaces but none of them other
        // than the current one is the ordinary single-Space Mac.
        guard let spaceIdentifiers = otherSpaceIdentifiers(in: displays) else {
            return nil
        }
        guard !spaceIdentifiers.isEmpty else {
            return []
        }

        var setTags = 0
        var clearTags = 0
        guard let windowIdentifiers = entrypoints.copyWindows(
            connection,
            0,
            spaceIdentifiers as CFArray,
            windowOptions,
            &setTags,
            &clearTags
        )?.takeRetainedValue() as? [CGWindowID], !windowIdentifiers.isEmpty else {
            return []
        }

        return owners(of: windowIdentifiers)
    }

    private static func otherSpaceIdentifiers(
        in displays: [NSDictionary]
    ) -> [UInt64]? {
        var currentIdentifiers: Set<UInt64> = []
        var allIdentifiers: [UInt64] = []

        for display in displays {
            if let current = display["Current Space"] as? NSDictionary,
               let identifier = current["id64"] as? UInt64 {
                currentIdentifiers.insert(identifier)
            }

            for space in display["Spaces"] as? [NSDictionary] ?? [] {
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

    private static func owners(
        of windowIdentifiers: [CGWindowID]
    ) -> Set<pid_t> {
        guard let descriptions = WindowServerDescriptionReader.descriptions(
            for: windowIdentifiers
        ) else {
            return []
        }

        return descriptions.reduce(into: Set<pid_t>()) { owners, description in
            // The same window level the on-screen pass uses: level 0 separates
            // ordinary application windows from the menu bar, Control Center
            // and wallpaper windows every application carries around.
            guard description[kCGWindowLayer as String] as? Int == 0,
                  let processIdentifier = description[
                      kCGWindowOwnerPID as String
                  ] as? Int else {
                return
            }

            owners.insert(pid_t(processIdentifier))
        }
    }
}
