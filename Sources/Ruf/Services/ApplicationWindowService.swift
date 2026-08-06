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
        let menuDepth: Int
    }

    private enum MenuBarQueryResult {
        case found(AXUIElement)
        case incomplete
        case noMatch
    }

    // How much of a menu tree one traversal managed to read. Two identical
    // readings mean the tree has stopped changing under it.
    private struct MenuSearchCoverage: Equatable {
        let visited: Int
        let queued: Int
        let wasIncomplete: Bool
    }

    private struct ApplicationWindowsQuery: Sendable {
        let hasSwitchableAXWindows: Bool
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
        for processIdentifiers: [pid_t],
        hiddenProcessIdentifiers: Set<pid_t>
    ) async -> [pid_t: ApplicationWindowState] {
        let queryTask = Task.detached(priority: .userInitiated) {
            await queryStates(
                for: processIdentifiers,
                hiddenProcessIdentifiers: hiddenProcessIdentifiers
            )
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

        // The search defers a shortcut match while an incomplete read can still
        // be retried, and falls back to it once the budget expires. That last
        // attempt starts after the deadline and returns before traversing
        // anything, so the match has to outlive the attempt that found it.
        var shortcutFallback: AXUIElement?
        var previousCoverage: MenuSearchCoverage?

        while !Task.isCancelled {
            let outcome: NewWindowMenuSearchOutcome
            var coverage = MenuSearchCoverage(
                visited: 0,
                queued: 0,
                wasIncomplete: true
            )
            switch menuBar(from: applicationElement) {
            case let .found(menuBar):
                outcome = searchNewWindowMenuItem(
                    in: menuBar,
                    deadline: deadline,
                    shortcutFallback: &shortcutFallback,
                    coverage: &coverage
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
                if NewWindowMenuSearchDecision.shouldPressDeferredFallback(
                    hasFallback: shortcutFallback != nil,
                    coverageRepeated: coverage == previousCoverage
                ), let shortcutFallback {
                    return requestNewWindowAction(
                        on: shortcutFallback
                    ) == .actionRequested
                        ? .menuActionRequested
                        : .unavailable
                }

                previousCoverage = coverage
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
        deadline: DispatchTime,
        shortcutFallback: inout AXUIElement?,
        coverage: inout MenuSearchCoverage
    ) -> NewWindowMenuSearchOutcome {
        var elements = [
            MenuTraversalEntry(
                element: menuBar,
                isInsideNewWindowSubmenu: false,
                menuDepth: 0
            ),
        ]
        var index = 0
        var wasIncomplete = false
        defer {
            coverage = MenuSearchCoverage(
                visited: index,
                queued: elements.count,
                wasIncomplete: wasIncomplete
            )
        }

        while index < elements.count {
            guard !Task.isCancelled else {
                return .noMatch
            }

            let hasTimeRemaining = DispatchTime.now() < deadline
            guard hasTimeRemaining else {
                return resolveDeferredNewWindowSearch(
                    shortcutFallback: shortcutFallback,
                    wasIncomplete: wasIncomplete,
                    hasTimeRemaining: false
                )
            }

            let entry = elements[index]
            if entry.menuDepth > 1, shortcutFallback != nil {
                return resolveDeferredNewWindowSearch(
                    shortcutFallback: shortcutFallback,
                    wasIncomplete: wasIncomplete,
                    hasTimeRemaining: true
                )
            }

            index += 1

            let element = entry.element
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
            let isDirectTopLevelMenuItem = isMenuItem
                && entry.menuDepth == 1
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
                        || isDirectTopLevelMenuItem
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


            let match = isMenuItem
                ? NewWindowMenuItemMatcher.match(
                    title: title,
                    isEnabled: isEnabled,
                    hasChildren: hasChildren,
                    isInsideNewWindowSubmenu: entry.isInsideNewWindowSubmenu,
                    isDirectTopLevelMenuItem: isDirectTopLevelMenuItem,
                    commandCharacter: commandCharacter,
                    commandModifiers: commandModifiers
                )
                : .none

            switch match {
            case .exactTitle:
                return requestNewWindowAction(on: element)
            case .shortcutFallback:
                if entry.isInsideNewWindowSubmenu {
                    return requestNewWindowAction(on: element)
                }
                shortcutFallback = shortcutFallback ?? element
            case .none:
                break
            }

            let isInsideNewWindowSubmenu = entry.isInsideNewWindowSubmenu
                || entersNewWindowSubmenu
            let remainingCapacity = maximumMenuElementCount - elements.count
            if children.count > remainingCapacity {
                wasIncomplete = true
            }

            let childMenuDepth = entry.menuDepth
                + (role == kAXMenuRole ? 1 : 0)
            let appendedChildren = children.prefix(remainingCapacity)
            for child in appendedChildren {
                elements.append(
                    MenuTraversalEntry(
                        element: child,
                        isInsideNewWindowSubmenu: isInsideNewWindowSubmenu,
                        menuDepth: childMenuDepth
                    )
                )
            }
        }

        return resolveDeferredNewWindowSearch(
            shortcutFallback: shortcutFallback,
            wasIncomplete: wasIncomplete,
            hasTimeRemaining: DispatchTime.now() < deadline
        )
    }

    private static func resolveDeferredNewWindowSearch(
        shortcutFallback: AXUIElement?,
        wasIncomplete: Bool,
        hasTimeRemaining: Bool
    ) -> NewWindowMenuSearchOutcome {
        switch NewWindowMenuSearchDecision.deferredDecision(
            hasFallback: shortcutFallback != nil,
            wasIncomplete: wasIncomplete,
            hasTimeRemaining: hasTimeRemaining
        ) {
        case .requestFallback:
            guard let shortcutFallback else {
                return .noMatch
            }
            return requestNewWindowAction(on: shortcutFallback)
        case .reportIncomplete:
            return .incomplete
        case .noMatch:
            return .noMatch
        }
    }

    private static func requestNewWindowAction(
        on element: AXUIElement
    ) -> NewWindowMenuSearchOutcome {
        guard !Task.isCancelled else {
            return .noMatch
        }

        // The deferred match can be pressed a whole budget after it was found,
        // by which point the menu may have been rebuilt. Reporting success
        // without checking would turn that into a silently ignored request.
        let error = AXClientContext.withDefaultIdentity {
            AXUIElementPerformAction(
                element,
                kAXPressAction as CFString
            )
        }
        return error == .success ? .actionRequested : .noMatch
    }

    private static func queryStates(
        for processIdentifiers: [pid_t],
        hiddenProcessIdentifiers: Set<pid_t>
    ) async -> [pid_t: ApplicationWindowState] {
        guard !Task.isCancelled, AccessibilityPermission.isGranted else {
            return [:]
        }

        let windowListSpan = PerformanceLog.begin("ax.windowList")
        let visibleWindowIdentifiers = visibleWindowIdentifiers()
        PerformanceLog.end(windowListSpan)

        guard let visibleWindowIdentifiers else {
            return [:]
        }

        let querySpan = PerformanceLog.begin("ax.queryStates")
        let deadline = DispatchTime.now() + totalQueryBudget
        let plan = WindowQueryPlan(
            processIdentifiers: processIdentifiers,
            visibleWindowIdentifiers: visibleWindowIdentifiers
        )

        return await withTaskGroup(
            of: WindowStateQueryResult.self
        ) { group in
            var candidates = plan.windowQueryCandidates.makeIterator()
            var dispatchedCount = 0
            let initialQueryCount = min(
                maximumConcurrentApplicationQueries,
                plan.windowQueryCandidates.count
            )

            for _ in 0..<initialQueryCount {
                guard !Task.isCancelled,
                      let processIdentifier = candidates.next() else {
                    break
                }

                dispatchedCount += 1
                group.addTask {
                    queryState(
                        for: processIdentifier,
                        isApplicationHidden: hiddenProcessIdentifiers.contains(
                            processIdentifier
                        ),
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

                dispatchedCount += 1
                group.addTask {
                    queryState(
                        for: processIdentifier,
                        isApplicationHidden: hiddenProcessIdentifiers.contains(
                            processIdentifier
                        ),
                        plan: plan,
                        deadline: deadline
                    )
                }
            }

            // A candidate that was never dispatched, or that resolved to no
            // state, is an application the switcher silently degrades to an
            // app-level tile. That ratio is the signal the budget is too tight,
            // not the elapsed time on its own.
            PerformanceLog.end(
                querySpan,
                "candidates=\(plan.windowQueryCandidates.count) "
                    + "dispatched=\(dispatchedCount) "
                    + "resolved=\(states.count) "
                    + "budgetExpired=\(DispatchTime.now() >= deadline)"
            )
            return states
        }
    }

    private static func queryState(
        for processIdentifier: pid_t,
        isApplicationHidden: Bool,
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
            hasSwitchableAXWindows: query.hasSwitchableAXWindows,
            hasVisibleWindows: plan.hasVisibleWindows(
                for: processIdentifier
            ),
            isApplicationHidden: isApplicationHidden,
            switchableWindowMinimizedStates: query.windows.map(\.isMinimized)
        )
        let state: ApplicationWindowState?

        switch disposition {
        case .application:
            state = nil
        case .singleWindow:
            state = query.windows.first.map(
                ApplicationWindowState.singleWindow
            )
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
        var hasSwitchableAXWindows = false
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
                    || subrole == kAXDialogSubrole
            else {
                continue
            }

            // The subrole already establishes this is a window the user can be
            // switched to. Its title only decides what the cell reads.
            hasSwitchableAXWindows = true
            let trimmedTitle = title?.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            let displayTitle = trimmedTitle?.isEmpty == false
                ? trimmedTitle
                : nil

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
                    title: displayTitle,
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
            hasSwitchableAXWindows: hasSwitchableAXWindows,
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
