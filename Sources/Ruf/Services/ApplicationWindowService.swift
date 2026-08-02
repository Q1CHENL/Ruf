import AppKit
import ApplicationServices
import Foundation

enum ApplicationWindowService {
    private static let messageTimeout: Float = 0.075
    private static let queryBudget = DispatchTimeInterval.milliseconds(250)

    static func multipleWindows(
        for processIdentifiers: [pid_t]
    ) async -> [pid_t: [ApplicationWindow]] {
        await Task.detached(priority: .userInitiated) {
            queryWindows(for: processIdentifiers)
        }.value
    }

    @MainActor
    static func activate(
        _ window: ApplicationWindow,
        in application: NSRunningApplication
    ) {
        application.activate()
        AXUIElementSetAttributeValue(
            window.element,
            kAXMainAttribute as CFString,
            kCFBooleanTrue
        )
        AXUIElementPerformAction(window.element, kAXRaiseAction as CFString)
    }

    private static func queryWindows(
        for processIdentifiers: [pid_t]
    ) -> [pid_t: [ApplicationWindow]] {
        guard AccessibilityPermission.isGranted else {
            return [:]
        }

        let candidates = applicationsWithMultipleVisibleWindows()
        let deadline = DispatchTime.now() + queryBudget
        var windowsByProcessIdentifier: [pid_t: [ApplicationWindow]] = [:]

        for processIdentifier in processIdentifiers
        where candidates.contains(processIdentifier) {
            guard DispatchTime.now() < deadline else {
                break
            }

            let windows = windows(
                for: processIdentifier,
                deadline: deadline
            )
            guard windows.count > 1 else {
                continue
            }

            windowsByProcessIdentifier[processIdentifier] = windows
        }

        return windowsByProcessIdentifier
    }

    private static func applicationsWithMultipleVisibleWindows() -> Set<pid_t> {
        // AX calls cross process boundaries, so use the fast WindowServer
        // snapshot to avoid querying every running application.
        let options: CGWindowListOption = [
            .optionOnScreenOnly,
            .excludeDesktopElements,
        ]
        guard let windowInfo = CGWindowListCopyWindowInfo(
            options,
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return []
        }

        let windowCounts = windowInfo.reduce(into: [pid_t: Int]()) { counts, window in
            guard
                window[kCGWindowLayer as String] as? Int == 0,
                let processIdentifier = window[kCGWindowOwnerPID as String] as? Int
            else {
                return
            }

            counts[pid_t(processIdentifier), default: 0] += 1
        }

        return Set(
            windowCounts.compactMap { processIdentifier, windowCount in
                windowCount > 1 ? processIdentifier : nil
            }
        )
    }

    private static func windows(
        for processIdentifier: pid_t,
        deadline: DispatchTime
    ) -> [ApplicationWindow] {
        let applicationElement = AXUIElementCreateApplication(processIdentifier)
        AXUIElementSetMessagingTimeout(applicationElement, messageTimeout)

        guard let applicationValues = values(
            of: [kAXWindowsAttribute, kAXFocusedWindowAttribute],
            from: applicationElement
        ), DispatchTime.now() < deadline,
           let elements = applicationValues[0] as? [AXUIElement] else {
            return []
        }

        let focusedWindow: AXUIElement? = decoded(applicationValues[1])
        var windows: [ApplicationWindow] = []

        for element in elements {
            guard DispatchTime.now() < deadline else {
                return []
            }

            AXUIElementSetMessagingTimeout(element, messageTimeout)
            guard let windowValues = values(
                of: [
                    kAXSubroleAttribute,
                    kAXMinimizedAttribute,
                    kAXTitleAttribute,
                ],
                from: element
            ) else {
                return []
            }

            let subrole: String? = decoded(windowValues[0])
            let isMinimized: Bool = decoded(windowValues[1]) ?? false
            let title: String? = decoded(windowValues[2])
            guard
                let subrole,
                subrole == kAXStandardWindowSubrole
                    || subrole == kAXDialogSubrole,
                !isMinimized,
                let title
            else {
                continue
            }

            let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedTitle.isEmpty else {
                continue
            }

            windows.append(ApplicationWindow(element: element, title: trimmedTitle))
        }

        guard DispatchTime.now() < deadline else {
            return []
        }

        if let focusedWindow,
           let focusedIndex = windows.firstIndex(where: {
               CFEqual($0.element, focusedWindow)
           }) {
            windows.insert(windows.remove(at: focusedIndex), at: 0)
        }

        return windows
    }

    private static func values(
        of attributes: [String],
        from element: AXUIElement
    ) -> [Any]? {
        var rawValues: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(
            element,
            attributes as CFArray,
            [],
            &rawValues
        ) == .success,
              let rawValues,
              let values = rawValues as? [Any],
              values.count == attributes.count else {
            return nil
        }

        return values
    }

    private static func decoded<Value>(_ value: Any) -> Value? {
        let rawValue = value as CFTypeRef
        guard CFGetTypeID(rawValue) != AXValueGetTypeID() else {
            return nil
        }

        return rawValue as? Value
    }
}
