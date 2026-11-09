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
        case unsupported
    }

    enum PressResult: Equatable {
        case delivered
        case stale
        case failed
    }

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
        var fallback: AXUIElement?
        var previousCoverage: NewWindowMenuSearchCoverage?

        while !Task.isCancelled {
            let attempt = searchAttempt(
                in: applicationElement,
                fallback: fallback,
                deadline: deadline
            )
            fallback = attempt.fallback

            switch NewWindowMenuSearchDecision.nextStep(
                after: attempt,
                previousCoverage: previousCoverage,
                hasTimeRemaining: DispatchTime.now() < deadline
            ) {
            case let .press(element):
                guard !Task.isCancelled else {
                    return .unavailable
                }

                switch press(element) {
                case .delivered:
                    return .menuActionRequested
                case .stale:
                    // The menu was rebuilt after it was read, so none of the
                    // items read from it, the fallback included, still exist.
                    fallback = nil
                    previousCoverage = nil
                    guard DispatchTime.now() < deadline else {
                        return .unavailable
                    }
                case .failed:
                    return .unavailable
                }
            case .retry:
                previousCoverage = attempt.coverage
            case .giveUp:
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
            return .unsupported
        }

        return .incomplete
    }

    private static func searchAttempt(
        in applicationElement: AXUIElement,
        fallback: AXUIElement?,
        deadline: DispatchTime
    ) -> NewWindowMenuSearchAttempt<AXUIElement> {
        let isComplete: Bool
        switch menuBar(from: applicationElement) {
        case let .found(menuBar):
            return searchNewWindowMenuItem(
                in: menuBar,
                fallback: fallback,
                deadline: deadline
            )
        case .incomplete:
            isComplete = false
        case .unsupported:
            isComplete = true
        }

        return NewWindowMenuSearchAttempt(
            match: nil,
            fallback: fallback,
            isComplete: isComplete,
            coverage: NewWindowMenuSearchCoverage(visited: 0, queued: 0)
        )
    }

    private static func searchNewWindowMenuItem(
        in menuBar: AXUIElement,
        fallback carriedFallback: AXUIElement?,
        deadline: DispatchTime
    ) -> NewWindowMenuSearchAttempt<AXUIElement> {
        var elements = [
            TraversalEntry(
                element: menuBar,
                isInsideNewWindowSubmenu: false,
                menuDepth: 0
            ),
        ]
        var index = 0
        var fallback = carriedFallback
        var isComplete = true

        func attempt(
            match: AXUIElement? = nil
        ) -> NewWindowMenuSearchAttempt<AXUIElement> {
            NewWindowMenuSearchAttempt(
                match: match,
                fallback: fallback,
                isComplete: isComplete,
                coverage: NewWindowMenuSearchCoverage(
                    visited: index,
                    queued: elements.count
                )
            )
        }

        while index < elements.count {
            guard !Task.isCancelled,
                  DispatchTime.now() < deadline else {
                isComplete = false
                break
            }

            // The search is breadth-first, so every item of the top-level menus
            // has been read by now. Deeper submenus are searched only for an
            // application without a Command-N item to fall back to.
            let entry = elements[index]
            if entry.menuDepth > 1, fallback != nil {
                break
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
                isComplete = false
                continue
            }

            if AXElementReader.containsTransientError(in: menuValues) {
                isComplete = false
            }

            let role: String? = AXElementReader.decoded(menuValues[0])
            let title: String? = AXElementReader.decoded(menuValues[1])
            let isEnabled: Bool = AXElementReader.decoded(menuValues[2]) ?? false
            guard let children = menuChildren(from: menuValues[3]) else {
                isComplete = false
                continue
            }

            let isMenuItem = role == kAXMenuItemRole
            let hasChildren = !children.isEmpty
            let match = isMenuItem
                ? NewWindowMenuItemMatcher.match(
                    title: title,
                    isEnabled: isEnabled,
                    hasChildren: hasChildren,
                    isInsideNewWindowSubmenu: entry.isInsideNewWindowSubmenu,
                    isDirectTopLevelMenuItem: entry.menuDepth == 1,
                    commandShortcut: {
                        commandShortcut(of: element, isComplete: &isComplete)
                    }
                )
                : .none

            switch match {
            case .newWindow:
                return attempt(match: element)
            case .shortcutFallback:
                fallback = element
            case .none:
                break
            }

            let isInsideNewWindowSubmenu = entry.isInsideNewWindowSubmenu
                || (
                    isMenuItem
                        && isEnabled
                        && hasChildren
                        && title.map(NewWindowMenuTitleMatcher.matches) == true
                )
            let remainingCapacity = maximumElementCount - elements.count
            if children.count > remainingCapacity {
                isComplete = false
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

        return attempt()
    }

    private static func commandShortcut(
        of element: AXUIElement,
        isComplete: inout Bool
    ) -> (character: String?, modifiers: UInt32?) {
        guard let commandValues = AXElementReader.values(
            of: [
                kAXMenuItemCmdCharAttribute,
                kAXMenuItemCmdModifiersAttribute,
            ],
            from: element
        ) else {
            isComplete = false
            return (nil, nil)
        }

        if AXElementReader.containsTransientError(in: commandValues) {
            isComplete = false
        }

        let modifiers: NSNumber? = AXElementReader.decoded(commandValues[1])
        return (AXElementReader.decoded(commandValues[0]), modifiers?.uint32Value)
    }

    private static func press(_ element: AXUIElement) -> PressResult {
        pressResult(
            for: AXClientContext.withDefaultIdentity {
                AXUIElementPerformAction(
                    element,
                    kAXPressAction as CFString
                )
            }
        )
    }

    // Pressing again is safe only when the error proves the first press never
    // reached the application.
    static func pressResult(for error: AXError) -> PressResult {
        switch error {
        case .success:
            .delivered
        // The messaging timeout expired while the application was still
        // carrying out the press. Slow applications do this routinely, and a
        // second press would open a second window.
        case .cannotComplete:
            .delivered
        // A fallback can be pressed a whole budget after it was read, by which
        // point the menu may have been rebuilt and the item is gone.
        case .invalidUIElement:
            .stale
        default:
            .failed
        }
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
