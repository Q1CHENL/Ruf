import AppKit
import ApplicationServices
import Foundation
import RufCore

enum NewWindowMenuService {
    enum OpenResult: Sendable {
        case menuActionRequested
        case unavailable
    }

    private struct TraversalEntry {
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
    private struct SearchCoverage: Equatable {
        let visited: Int
        let queued: Int
    }

    // AX has no menu-tree-ready notification. Incomplete reads are polled
    // within this bounded interaction budget; complete searches return early.
    private static let messageTimeout: Float = 0.2
    private static let queryBudget = DispatchTimeInterval.milliseconds(1_500)
    private static let retryInterval: Duration = .milliseconds(20)
    private static let maximumElementCount = 5_000

    @MainActor
    static func open(
        in application: NSRunningApplication
    ) async -> OpenResult {
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
    ) async -> OpenResult {
        guard AccessibilityPermission.isGranted else {
            return .unavailable
        }

        let applicationElement = AXClientContext.applicationElement(
            for: processIdentifier
        )
        AXClientContext.setMessagingTimeout(
            messageTimeout,
            for: applicationElement
        )
        let deadline = DispatchTime.now() + queryBudget

        // The search defers a shortcut match while an incomplete read can still
        // be retried, and falls back to it once the budget expires. That last
        // attempt starts after the deadline and returns before traversing
        // anything, so the match has to outlive the attempt that found it.
        var shortcutFallback: AXUIElement?
        var previousCoverage: SearchCoverage?

        while !Task.isCancelled {
            var outcome: NewWindowMenuSearchOutcome
            var coverage = SearchCoverage(
                visited: 0,
                queued: 0
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

            // A tree that reports identical coverage twice has stopped being
            // built, so waiting out the remaining budget only delays a match
            // already in hand.
            if outcome == .incomplete,
               coverage == previousCoverage,
               let shortcutFallback {
                outcome = requestNewWindowAction(on: shortcutFallback)
            }

            switch outcome {
            case .actionRequested:
                return .menuActionRequested
            case .noMatch:
                return .unavailable
            case .actionFailed:
                shortcutFallback = nil
                previousCoverage = nil
            case .incomplete:
                previousCoverage = coverage
            }

            guard NewWindowMenuSearchDecision.shouldRetry(
                after: outcome,
                hasTimeRemaining: DispatchTime.now() < deadline
            ) else {
                return .unavailable
            }

            do {
                try await Task.sleep(for: retryInterval)
            } catch {
                return .unavailable
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

        if AXElementReader.error(from: applicationValues[0])
            == .attributeUnsupported {
            return .noMatch
        }

        return .incomplete
    }

    private static func searchNewWindowMenuItem(
        in menuBar: AXUIElement,
        deadline: DispatchTime,
        shortcutFallback: inout AXUIElement?,
        coverage: inout SearchCoverage
    ) -> NewWindowMenuSearchOutcome {
        var elements = [
            TraversalEntry(
                element: menuBar,
                isInsideNewWindowSubmenu: false,
                menuDepth: 0
            ),
        ]
        var index = 0
        var wasIncomplete = false
        defer {
            coverage = SearchCoverage(
                visited: index,
                queued: elements.count
            )
        }

        while index < elements.count {
            guard !Task.isCancelled else {
                return .noMatch
            }

            let hasTimeRemaining = DispatchTime.now() < deadline
            guard hasTimeRemaining else {
                return resolveDeferredSearch(
                    shortcutFallback: shortcutFallback,
                    wasIncomplete: wasIncomplete,
                    hasTimeRemaining: false
                )
            }

            let entry = elements[index]
            if entry.menuDepth > 1, shortcutFallback != nil {
                return resolveDeferredSearch(
                    shortcutFallback: shortcutFallback,
                    wasIncomplete: wasIncomplete,
                    hasTimeRemaining: true
                )
            }

            index += 1

            let element = entry.element
            AXClientContext.setMessagingTimeout(messageTimeout, for: element)

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

            if AXElementReader.containsTransientError(in: menuValues) {
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
            let isDirectTopLevelMenuItem = isMenuItem && entry.menuDepth == 1
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

                if AXElementReader.containsTransientError(in: commandValues) {
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
                shortcutFallback = element
            case .none:
                break
            }

            let isInsideNewWindowSubmenu = entry.isInsideNewWindowSubmenu
                || entersNewWindowSubmenu
            let remainingCapacity = maximumElementCount - elements.count
            if children.count > remainingCapacity {
                wasIncomplete = true
            }

            let childMenuDepth = entry.menuDepth
                + (role == kAXMenuRole ? 1 : 0)
            for child in children.prefix(remainingCapacity) {
                elements.append(
                    TraversalEntry(
                        element: child,
                        isInsideNewWindowSubmenu: isInsideNewWindowSubmenu,
                        menuDepth: childMenuDepth
                    )
                )
            }
        }

        return resolveDeferredSearch(
            shortcutFallback: shortcutFallback,
            wasIncomplete: wasIncomplete,
            hasTimeRemaining: DispatchTime.now() < deadline
        )
    }

    private static func resolveDeferredSearch(
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
        return error == .success ? .actionRequested : .actionFailed
    }

    private static func menuChildren(
        from value: Any
    ) -> [AXUIElement]? {
        if let children: [AXUIElement] = AXElementReader.decoded(value) {
            return children
        }

        switch AXElementReader.error(from: value) {
        case .attributeUnsupported?, .noValue?:
            return []
        default:
            return nil
        }
    }
}
