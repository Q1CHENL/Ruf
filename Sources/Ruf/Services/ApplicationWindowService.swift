import AppKit
import ApplicationServices
import Foundation

enum ApplicationWindowService {
    private static let messageTimeout: Float = 0.075
    private static let queryBudget = DispatchTimeInterval.milliseconds(250)

    static func states(
        for processIdentifiers: [pid_t]
    ) async -> [pid_t: ApplicationWindowState] {
        await Task.detached(priority: .userInitiated) {
            queryStates(for: processIdentifiers)
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

    @MainActor
    static func reopen(_ application: NSRunningApplication) {
        guard let bundleURL = application.bundleURL else {
            application.activate(options: [.activateAllWindows])
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false
        NSWorkspace.shared.openApplication(
            at: bundleURL,
            configuration: configuration,
            completionHandler: nil
        )
    }

    private static func queryStates(
        for processIdentifiers: [pid_t]
    ) -> [pid_t: ApplicationWindowState] {
        guard
            AccessibilityPermission.isGranted,
            let visibleWindowCounts = visibleWindowCounts()
        else {
            return [:]
        }

        let deadline = DispatchTime.now() + queryBudget
        var states: [pid_t: ApplicationWindowState] = [:]

        for processIdentifier in processIdentifiers {
            guard DispatchTime.now() < deadline else {
                break
            }

            switch visibleWindowCounts[processIdentifier, default: 0] {
            case 0:
                // Only a successful empty AX window list is safe to badge as
                // reopenable; another Space and query failures stay ordinary.
                guard let hasWindows = hasWindows(
                    for: processIdentifier,
                    deadline: deadline
                ), !hasWindows else {
                    continue
                }

                states[processIdentifier] = .windowless
            case 1:
                continue
            default:
                let windows = windows(
                    for: processIdentifier,
                    deadline: deadline
                )
                guard windows.count > 1 else {
                    continue
                }

                states[processIdentifier] = .multiple(windows)
            }
        }

        return states
    }

    private static func visibleWindowCounts() -> [pid_t: Int]? {
        // One visible WindowServer window is already an ordinary app target.
        // AX is only needed to distinguish zero windows from another Space,
        // or to enumerate apps with multiple visible windows.
        let options: CGWindowListOption = [
            .optionOnScreenOnly,
            .excludeDesktopElements,
        ]
        guard let windowInfo = CGWindowListCopyWindowInfo(
            options,
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return nil
        }

        return windowInfo.reduce(into: [pid_t: Int]()) { counts, window in
            guard
                window[kCGWindowLayer as String] as? Int == 0,
                let processIdentifier = window[kCGWindowOwnerPID as String] as? Int
            else {
                return
            }

            counts[pid_t(processIdentifier), default: 0] += 1
        }
    }

    private static func hasWindows(
        for processIdentifier: pid_t,
        deadline: DispatchTime
    ) -> Bool? {
        let applicationElement = AXUIElementCreateApplication(processIdentifier)
        AXUIElementSetMessagingTimeout(applicationElement, messageTimeout)

        guard
            let applicationValues = values(
                of: [kAXWindowsAttribute],
                from: applicationElement
            ),
            DispatchTime.now() < deadline,
            let elements = applicationValues[0] as? [AXUIElement]
        else {
            return nil
        }

        return !elements.isEmpty
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
