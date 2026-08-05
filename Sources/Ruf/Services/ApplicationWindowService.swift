import AppKit
import ApplicationServices
import Foundation
import RufCore

enum ApplicationWindowService {
    enum NewWindowOpenResult: Sendable {
        case menuActionRequested
        case unavailable
    }

    private struct MenuTraversalEntry {
        let element: AXUIElement
        let isInsideNewWindowSubmenu: Bool
        let isInsideFileMenu: Bool
    }

    private enum MenuBarQueryResult {
        case found(AXUIElement)
        case incomplete
        case noMatch
    }

    private struct ApplicationWindowsQuery: Sendable {
        let hasAXWindows: Bool
        let windows: [ApplicationWindow]
    }

    private struct WindowStateQueryResult: Sendable {
        let processIdentifier: pid_t
        let state: ApplicationWindowState?
    }

    private static let messageTimeout: Float = 0.075
    private static let totalQueryBudget = DispatchTimeInterval.milliseconds(250)
    // AX calls block in the target process. A small bounded pool prevents one
    // busy app from consuming the whole snapshot without flooding the AX server.
    private static let maximumConcurrentApplicationQueries = 4
    // AX has no menu-tree-ready notification. Incomplete reads are polled
    // within this bounded interaction budget; complete searches return early.
    private static let menuMessageTimeout: Float = 0.2
    private static let menuQueryBudget = DispatchTimeInterval.milliseconds(1_500)
    private static let menuRetryInterval: Duration = .milliseconds(20)
    private static let maximumMenuElementCount = 5_000

    static func states(
        for processIdentifiers: [pid_t]
    ) async -> [pid_t: ApplicationWindowState] {
        let queryTask = Task.detached(priority: .userInitiated) {
            await queryStates(for: processIdentifiers)
        }

        return await withTaskCancellationHandler {
            await queryTask.value
        } onCancel: {
            queryTask.cancel()
        }
    }

    @MainActor
    static func activate(
        _ window: ApplicationWindow,
        in application: NSRunningApplication
    ) {
        if window.isMinimized {
            _ = AXClientContext.withDefaultIdentity {
                AXUIElementSetAttributeValue(
                    window.element,
                    kAXMinimizedAttribute as CFString,
                    kCFBooleanFalse
                )
            }
        }

        application.activate()
        AXClientContext.withDefaultIdentity {
            _ = AXUIElementSetAttributeValue(
                window.element,
                kAXMainAttribute as CFString,
                kCFBooleanTrue
            )
            _ = AXUIElementPerformAction(
                window.element,
                kAXRaiseAction as CFString
            )
        }
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
        guard await ApplicationActivation.activate(application) else {
            return .unavailable
        }
        guard !Task.isCancelled else {
            return .unavailable
        }

        let processIdentifier = application.processIdentifier
        let queryTask = Task.detached(priority: .userInitiated) {
            await pressNewWindowMenuItem(for: processIdentifier)
        }

        return await withTaskCancellationHandler {
            await queryTask.value
        } onCancel: {
            queryTask.cancel()
        }
    }

    private static func pressNewWindowMenuItem(
        for processIdentifier: pid_t
    ) async -> NewWindowOpenResult {
        guard AccessibilityPermission.isGranted else {
            return .unavailable
        }

        let applicationElement = AXClientContext.applicationElement(
            for: processIdentifier
        )
        AXClientContext.setMessagingTimeout(
            menuMessageTimeout,
            for: applicationElement
        )
        let deadline = DispatchTime.now() + menuQueryBudget

        while !Task.isCancelled {
            let outcome: NewWindowMenuSearchOutcome
            switch menuBar(from: applicationElement) {
            case let .found(menuBar):
                outcome = searchNewWindowMenuItem(
                    in: menuBar,
                    deadline: deadline
                )
            case .incomplete:
                outcome = .incomplete
            case .noMatch:
                outcome = .noMatch
            }

            switch outcome {
            case .actionRequested:
                return .menuActionRequested
            case .noMatch:
                return .unavailable
            case .incomplete:
                guard NewWindowMenuSearchDecision.shouldRetry(
                    after: outcome,
                    hasTimeRemaining: DispatchTime.now() < deadline
                ) else {
                    return .unavailable
                }

                do {
                    try await Task.sleep(for: menuRetryInterval)
                } catch {
                    return .unavailable
                }
            }
        }

        return .unavailable
    }

    private static func menuBar(
        from applicationElement: AXUIElement
    ) -> MenuBarQueryResult {
        guard let applicationValues = AXElementReader.values(
            of: [kAXMenuBarAttribute],
            from: applicationElement
        ) else {
            return .incomplete
        }

        if let menuBar: AXUIElement = AXElementReader.decoded(
            applicationValues[0]
        ) {
            return .found(menuBar)
        }

        if decodedAXError(applicationValues[0]) == .attributeUnsupported {
            return .noMatch
        }

        return .incomplete
    }

    private static func searchNewWindowMenuItem(
        in menuBar: AXUIElement,
        deadline: DispatchTime
    ) -> NewWindowMenuSearchOutcome {
        var elements = [
            MenuTraversalEntry(
                element: menuBar,
                isInsideNewWindowSubmenu: false,
                isInsideFileMenu: false
            ),
        ]
        var index = 0
        var wasIncomplete = false

        while index < elements.count {
            guard !Task.isCancelled,
                  DispatchTime.now() < deadline else {
                return .incomplete
            }

            let entry = elements[index]
            let element = entry.element
            index += 1
            AXClientContext.setMessagingTimeout(
                menuMessageTimeout,
                for: element
            )

            guard let menuValues = AXElementReader.values(
                of: [
                    kAXRoleAttribute,
                    kAXTitleAttribute,
                    kAXEnabledAttribute,
                    kAXChildrenAttribute,
                ],
                from: element
            ) else {
                wasIncomplete = true
                continue
            }

            if containsTransientAXError(menuValues) {
                wasIncomplete = true
            }

            let role: String? = AXElementReader.decoded(menuValues[0])
            let title: String? = AXElementReader.decoded(menuValues[1])
            let isEnabled: Bool = AXElementReader.decoded(menuValues[2]) ?? false
            guard let children = menuChildren(from: menuValues[3]) else {
                wasIncomplete = true
                continue
            }

            let isMenuItem = role == kAXMenuItemRole
            let hasChildren = !children.isEmpty
            let entersNewWindowSubmenu = isMenuItem
                && isEnabled
                && hasChildren
                && title.map(NewWindowMenuTitleMatcher.matches) == true

            var commandCharacter: String?
            var commandModifiers: UInt32?
            let requiresShortcutMatch = isMenuItem
                && isEnabled
                && !hasChildren
                && (
                    entry.isInsideNewWindowSubmenu
                        || entry.isInsideFileMenu
                )
                && title.map(NewWindowMenuTitleMatcher.matches) != true

            if requiresShortcutMatch {
                guard let commandValues = AXElementReader.values(
                    of: [
                        kAXMenuItemCmdCharAttribute,
                        kAXMenuItemCmdModifiersAttribute,
                    ],
                    from: element
                ) else {
                    wasIncomplete = true
                    continue
                }

                if containsTransientAXError(commandValues) {
                    wasIncomplete = true
                }

                commandCharacter = AXElementReader.decoded(commandValues[0])
                let modifierNumber: NSNumber? = AXElementReader.decoded(
                    commandValues[1]
                )
                commandModifiers = modifierNumber?.uint32Value
            }

            if isMenuItem,
               NewWindowMenuItemMatcher.shouldPress(
                   title: title,
                   isEnabled: isEnabled,
                   hasChildren: hasChildren,
                   isInsideNewWindowSubmenu: entry.isInsideNewWindowSubmenu,
                   isInsideFileMenu: entry.isInsideFileMenu,
                   commandCharacter: commandCharacter,
                   commandModifiers: commandModifiers
               ) {
                guard !Task.isCancelled else {
                    return .noMatch
                }
                AXClientContext.withDefaultIdentity {
                    _ = AXUIElementPerformAction(
                        element,
                        kAXPressAction as CFString
                    )
                }
                return .actionRequested
            }

            let isInsideNewWindowSubmenu = entry.isInsideNewWindowSubmenu
                || entersNewWindowSubmenu
            let isMenuBar = role == kAXMenuBarRole
            let remainingCapacity = maximumMenuElementCount - elements.count
            if children.count > remainingCapacity {
                wasIncomplete = true
            }
            for (childIndex, child) in children
                .prefix(remainingCapacity)
                .enumerated() {
                elements.append(
                    MenuTraversalEntry(
                        element: child,
                        isInsideNewWindowSubmenu: isInsideNewWindowSubmenu,
                        // AppKit reserves the first application menu item;
                        // the standard File menu is the second top-level item.
                        isInsideFileMenu: entry.isInsideFileMenu
                            || (isMenuBar && childIndex == 1)
                    )
                )
            }
        }

        return wasIncomplete ? .incomplete : .noMatch
    }

    private static func queryStates(
        for processIdentifiers: [pid_t]
    ) async -> [pid_t: ApplicationWindowState] {
        guard
            !Task.isCancelled,
            AccessibilityPermission.isGranted,
            let visibleWindowIdentifiers = visibleWindowIdentifiers()
        else {
            return [:]
        }

        let deadline = DispatchTime.now() + totalQueryBudget
        let plan = WindowQueryPlan(
            processIdentifiers: processIdentifiers,
            visibleWindowIdentifiers: visibleWindowIdentifiers
        )

        return await withTaskGroup(
            of: WindowStateQueryResult.self
        ) { group in
            var candidates = plan.windowQueryCandidates.makeIterator()
            let initialQueryCount = min(
                maximumConcurrentApplicationQueries,
                plan.windowQueryCandidates.count
            )

            for _ in 0..<initialQueryCount {
                guard !Task.isCancelled,
                      let processIdentifier = candidates.next() else {
                    break
                }

                group.addTask {
                    queryState(
                        for: processIdentifier,
                        plan: plan,
                        deadline: deadline
                    )
                }
            }

            var states: [pid_t: ApplicationWindowState] = [:]

            while let result = await group.next() {
                guard !Task.isCancelled else {
                    group.cancelAll()
                    continue
                }

                if let state = result.state {
                    states[result.processIdentifier] = state
                }

                guard DispatchTime.now() < deadline,
                      let processIdentifier = candidates.next() else {
                    continue
                }

                group.addTask {
                    queryState(
                        for: processIdentifier,
                        plan: plan,
                        deadline: deadline
                    )
                }
            }

            return states
        }
    }

    private static func queryState(
        for processIdentifier: pid_t,
        plan: WindowQueryPlan,
        deadline: DispatchTime
    ) -> WindowStateQueryResult {
        guard !Task.isCancelled,
              DispatchTime.now() < deadline,
              let query = windows(
                  for: processIdentifier,
                  plan: plan,
                  deadline: deadline
              ) else {
            return WindowStateQueryResult(
                processIdentifier: processIdentifier,
                state: nil
            )
        }

        let disposition = WindowQueryDisposition.resolve(
            hasAXWindows: query.hasAXWindows,
            hasVisibleWindows: plan.hasVisibleWindows(
                for: processIdentifier
            ),
            switchableWindowMinimizedStates: query.windows.map(\.isMinimized)
        )
        let state: ApplicationWindowState?

        switch disposition {
        case .application:
            state = nil
        case .windowless:
            state = .windowless
        case .windows:
            state = .windows(query.windows)
        }

        return WindowStateQueryResult(
            processIdentifier: processIdentifier,
            state: state
        )
    }

    private static func visibleWindowIdentifiers() -> [pid_t: Set<CGWindowID>]? {
        // AX is queried for every app so minimized windows can be recognized.
        // These WindowServer identifiers remain authoritative for ordinary
        // visible windows and reject other-Space, ordered-out, and ghost AX
        // elements without hiding windows explicitly marked as minimized.
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

        return windowInfo.reduce(into: [pid_t: Set<CGWindowID>]()) {
            identifiers, window in
            guard
                window[kCGWindowLayer as String] as? Int == 0,
                let processIdentifier = window[
                    kCGWindowOwnerPID as String
                ] as? Int,
                let windowIdentifier = window[
                    kCGWindowNumber as String
                ] as? CGWindowID
            else {
                return
            }

            identifiers[pid_t(processIdentifier), default: []].insert(
                windowIdentifier
            )
        }
    }

    private static func windows(
        for processIdentifier: pid_t,
        plan: WindowQueryPlan,
        deadline: DispatchTime
    ) -> ApplicationWindowsQuery? {
        let applicationElement = AXClientContext.applicationElement(
            for: processIdentifier
        )
        AXClientContext.setMessagingTimeout(
            messageTimeout,
            for: applicationElement
        )

        guard let applicationValues = AXElementReader.values(
            of: [kAXWindowsAttribute, kAXFocusedWindowAttribute],
            from: applicationElement
        ), DispatchTime.now() < deadline,
           let elements = applicationValues[0] as? [AXUIElement] else {
            return nil
        }

        let focusedWindow: AXUIElement? = AXElementReader.decoded(
            applicationValues[1]
        )
        var windows: [ApplicationWindow] = []

        for element in elements {
            guard !Task.isCancelled,
                  DispatchTime.now() < deadline else {
                break
            }

            AXClientContext.setMessagingTimeout(messageTimeout, for: element)
            guard let windowValues = AXElementReader.values(
                of: [
                    kAXSubroleAttribute,
                    kAXMinimizedAttribute,
                    kAXTitleAttribute,
                ],
                from: element
            ) else {
                continue
            }

            let subrole: String? = AXElementReader.decoded(windowValues[0])
            let isMinimized: Bool = AXElementReader.decoded(windowValues[1]) ?? false
            let title: String? = AXElementReader.decoded(windowValues[2])
            guard
                let subrole,
                subrole == kAXStandardWindowSubrole
                    || subrole == kAXDialogSubrole,
                let title
            else {
                continue
            }

            let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedTitle.isEmpty else {
                continue
            }

            let windowIdentifier = isMinimized
                ? nil
                : AXWindowIdentifierResolver.identifier(for: element)
            guard plan.shouldIncludeWindow(
                identifier: windowIdentifier,
                processIdentifier: processIdentifier,
                isMinimized: isMinimized
            ) else {
                continue
            }

            windows.append(
                ApplicationWindow(
                    element: element,
                    title: trimmedTitle,
                    isMinimized: isMinimized
                )
            )
        }

        if let focusedWindow,
           let focusedIndex = windows.firstIndex(where: {
               CFEqual($0.element, focusedWindow)
           }) {
            windows.insert(windows.remove(at: focusedIndex), at: 0)
        }

        return ApplicationWindowsQuery(
            hasAXWindows: !elements.isEmpty,
            windows: windows
        )
    }

    private static func menuChildren(
        from value: Any
    ) -> [AXUIElement]? {
        if let children: [AXUIElement] = AXElementReader.decoded(value) {
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

    private static func containsTransientAXError(_ values: [Any]) -> Bool {
        values.contains { value in
            guard let error = decodedAXError(value) else {
                return false
            }

            switch error {
            case .attributeUnsupported, .noValue:
                return false
            default:
                return true
            }
        }
    }
}
