import AppKit
import ApplicationServices
import Foundation
import RufCore

enum ApplicationWindowService {
    enum NewWindowOpenResult: Sendable {
        case menuActionPerformed
        case unavailable
    }

    private struct MenuTraversalEntry {
        let element: AXUIElement
        let isInsideNewWindowSubmenu: Bool
    }

    private static let messageTimeout: Float = 0.075
    private static let totalQueryBudget = DispatchTimeInterval.milliseconds(250)
    private static let reopenQueryBudget = DispatchTimeInterval.milliseconds(75)
    private static let menuQueryBudget = DispatchTimeInterval.milliseconds(500)
    private static let maximumMenuElementCount = 5_000

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
            completionHandler: { _, error in
                guard error != nil else {
                    return
                }

                Task { @MainActor in
                    application.activate(options: [.activateAllWindows])
                }
            }
        )
    }

    @MainActor
    static func openNewWindow(
        in application: NSRunningApplication
    ) async -> NewWindowOpenResult {
        application.activate()
        let processIdentifier = application.processIdentifier

        return await Task.detached(priority: .userInitiated) {
            pressNewWindowMenuItem(for: processIdentifier)
        }.value
    }

    private static func pressNewWindowMenuItem(
        for processIdentifier: pid_t
    ) -> NewWindowOpenResult {
        guard AccessibilityPermission.isGranted else {
            return .unavailable
        }

        let applicationElement = AXUIElementCreateApplication(processIdentifier)
        AXUIElementSetMessagingTimeout(applicationElement, messageTimeout)

        guard let applicationValues = values(
            of: [kAXMenuBarAttribute],
            from: applicationElement
        ), let menuBar: AXUIElement = decoded(applicationValues[0]) else {
            return .unavailable
        }

        let deadline = DispatchTime.now() + menuQueryBudget
        var elements = [
            MenuTraversalEntry(
                element: menuBar,
                isInsideNewWindowSubmenu: false
            ),
        ]
        var index = 0

        while index < elements.count,
              DispatchTime.now() < deadline {
            let entry = elements[index]
            let element = entry.element
            index += 1
            AXUIElementSetMessagingTimeout(element, messageTimeout)

            guard let menuValues = values(
                of: [
                    kAXRoleAttribute,
                    kAXTitleAttribute,
                    kAXEnabledAttribute,
                    kAXChildrenAttribute,
                    kAXMenuItemCmdCharAttribute,
                    kAXMenuItemCmdModifiersAttribute,
                ],
                from: element
            ) else {
                continue
            }

            let role: String? = decoded(menuValues[0])
            let title: String? = decoded(menuValues[1])
            let isEnabled: Bool = decoded(menuValues[2]) ?? false
            guard let children = menuChildren(from: menuValues[3]) else {
                continue
            }

            let commandCharacter: String? = decoded(menuValues[4])
            let commandModifierNumber: NSNumber? = decoded(menuValues[5])
            let isMenuItem = role == kAXMenuItemRole
            let hasChildren = !children.isEmpty
            let entersNewWindowSubmenu = isMenuItem
                && isEnabled
                && hasChildren
                && title.map(NewWindowMenuTitleMatcher.matches) == true

            if isMenuItem,
               NewWindowMenuItemMatcher.shouldPress(
                   title: title,
                   isEnabled: isEnabled,
                   hasChildren: hasChildren,
                   isInsideNewWindowSubmenu: entry.isInsideNewWindowSubmenu,
                   commandCharacter: commandCharacter,
                   commandModifiers: commandModifierNumber?.uint32Value
               ),
               AXUIElementPerformAction(
                   element,
                   kAXPressAction as CFString
               ) == .success {
                return .menuActionPerformed
            }

            let isInsideNewWindowSubmenu = entry.isInsideNewWindowSubmenu
                || entersNewWindowSubmenu
            let remainingCapacity = maximumMenuElementCount - elements.count
            for child in children.prefix(remainingCapacity) {
                elements.append(
                    MenuTraversalEntry(
                        element: child,
                        isInsideNewWindowSubmenu: isInsideNewWindowSubmenu
                    )
                )
            }
        }

        return .unavailable
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

        let deadline = DispatchTime.now() + totalQueryBudget
        let plan = WindowQueryPlan(
            processIdentifiers: processIdentifiers,
            visibleWindowCounts: visibleWindowCounts
        )
        var states: [pid_t: ApplicationWindowState] = [:]

        for processIdentifier in plan.multipleWindowCandidates {
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

            states[processIdentifier] = .multiple(windows)
        }

        // Window targets are the primary navigation feature. Reopen badges use
        // only the remaining global budget, capped at one AX timeout interval.
        let reopenDeadline = min(
            deadline,
            DispatchTime.now() + reopenQueryBudget
        )

        for processIdentifier in plan.reopenCandidates {
            guard DispatchTime.now() < reopenDeadline else {
                break
            }

            // Only a successful empty AX window list is safe to badge as
            // reopenable; another Space and query failures stay ordinary.
            guard let hasWindows = hasWindows(
                for: processIdentifier,
                deadline: reopenDeadline
            ), !hasWindows else {
                continue
            }

            states[processIdentifier] = .windowless
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

    private static func menuChildren(
        from value: Any
    ) -> [AXUIElement]? {
        if let children: [AXUIElement] = decoded(value) {
            return children
        }

        switch decodedAXError(value) {
        case .attributeUnsupported?, .noValue?:
            return []
        default:
            return nil
        }
    }

    private static func decodedAXError(_ value: Any) -> AXError? {
        let rawValue = value as CFTypeRef
        guard CFGetTypeID(rawValue) == AXValueGetTypeID() else {
            return nil
        }

        let axValue = rawValue as! AXValue
        guard AXValueGetType(axValue) == .axError else {
            return nil
        }

        var error: AXError = .success
        guard AXValueGetValue(axValue, .axError, &error) else {
            return nil
        }

        return error
    }
}
