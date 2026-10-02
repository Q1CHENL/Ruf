import AppKit
import ApplicationServices
import Foundation
import RufCore

enum ApplicationWindowService {
    struct Candidate: Sendable {
        let processIdentifier: pid_t
        let policy: ApplicationDiscoveryPolicy
        let isHidden: Bool
    }

    struct Snapshot: Sendable {
        let states: [pid_t: ApplicationWindowState]
        let plan: WindowQueryPlan?

        func includesApplication(
            _ processIdentifier: pid_t,
            policy: ApplicationDiscoveryPolicy
        ) -> Bool {
            let hasSwitchableWindows: Bool
            switch states[processIdentifier] {
            case .singleWindow?, .windows?:
                hasSwitchableWindows = true
            case .windowless?, nil:
                hasSwitchableWindows = false
            }
            return policy.shouldInclude(
                hasVisibleWindows: plan?.hasVisibleWindows(for: processIdentifier) ?? false,
                hasSwitchableWindows: hasSwitchableWindows
            )
        }
    }

    private struct ApplicationWindowsQuery: Sendable {
        let hasSwitchableAXWindows: Bool
        let hasIncompleteWindowReads: Bool
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

    static func snapshot(
        for candidates: [Candidate]
    ) async -> Snapshot {
        let queryTask = Task.detached(priority: .userInitiated) {
            await queryStates(for: candidates)
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

    private static func queryStates(
        for candidates: [Candidate]
    ) async -> Snapshot {
        guard !Task.isCancelled else {
            return Snapshot(states: [:], plan: nil)
        }

        let windowListSpan = PerformanceLog.begin("ax.windowList")
        let plan = windowQueryPlan()
        PerformanceLog.end(windowListSpan)

        guard let plan else {
            return Snapshot(states: [:], plan: nil)
        }
        guard AccessibilityPermission.isGranted else {
            return Snapshot(states: [:], plan: plan)
        }

        // Preserve the budget for regular apps and visible accessory windows;
        // probe remaining accessory owners for minimized windows afterward.
        var primaryCandidates: [Candidate] = []
        var secondaryCandidates: [Candidate] = []
        for candidate in candidates {
            switch candidate.policy.windowQueryPriority(
                hasWindowServerWindows: plan.hasWindows(for: candidate.processIdentifier),
                hasVisibleWindows: plan.hasVisibleWindows(for: candidate.processIdentifier)
            ) {
            case .primary:
                primaryCandidates.append(candidate)
            case .secondary:
                secondaryCandidates.append(candidate)
            case .skip:
                continue
            }
        }
        let queryCandidates = primaryCandidates + secondaryCandidates

        let spaceSpan = PerformanceLog.begin("ax.otherSpaceWindows")
        let otherSpaceWindowOwners = OtherSpaceWindowResolver
            .processIdentifiersWithWindows()
        PerformanceLog.end(
            spaceSpan,
            otherSpaceWindowOwners.map { "owners=\($0.count)" } ?? "unavailable"
        )

        let querySpan = PerformanceLog.begin("ax.queryStates")
        let deadline = DispatchTime.now() + totalQueryBudget
        let queryCandidate: @Sendable (Candidate) -> WindowStateQueryResult = { candidate in
            queryState(
                for: candidate.processIdentifier,
                isApplicationHidden: candidate.isHidden,
                otherSpaceWindowEvidence: OtherSpaceWindowEvidence(
                    hasWindows: otherSpaceWindowOwners?.contains(
                        candidate.processIdentifier
                    )
                ),
                plan: plan,
                deadline: deadline
            )
        }

        let states = await withTaskGroup(
            of: WindowStateQueryResult.self
        ) { group in
            var candidates = queryCandidates.makeIterator()
            var dispatchedCount = 0
            let initialQueryCount = min(
                maximumConcurrentApplicationQueries,
                queryCandidates.count
            )

            for _ in 0..<initialQueryCount {
                guard !Task.isCancelled,
                      let candidate = candidates.next() else {
                    break
                }

                dispatchedCount += 1
                group.addTask {
                    queryCandidate(candidate)
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
                      let candidate = candidates.next() else {
                    continue
                }

                dispatchedCount += 1
                group.addTask {
                    queryCandidate(candidate)
                }
            }

            // A candidate that was never dispatched, or that resolved to no
            // state, is an application the switcher silently degrades to an
            // app-level tile. That ratio is the signal the budget is too tight,
            // not the elapsed time on its own.
            PerformanceLog.end(
                querySpan,
                "candidates=\(queryCandidates.count) "
                    + "dispatched=\(dispatchedCount) "
                    + "resolved=\(states.count) "
                    + "budgetExpired=\(DispatchTime.now() >= deadline)"
            )
            return states
        }
        return Snapshot(states: states, plan: plan)
    }

    private static func queryState(
        for processIdentifier: pid_t,
        isApplicationHidden: Bool,
        otherSpaceWindowEvidence: OtherSpaceWindowEvidence,
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
            hasIncompleteWindowReads: query.hasIncompleteWindowReads,
            otherSpaceWindowEvidence: otherSpaceWindowEvidence,
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

    private static func windowQueryPlan() -> WindowQueryPlan? {
        // AX is queried for every app so minimized windows can be recognized.
        // These WindowServer identifiers remain authoritative for ordinary
        // visible windows and reject other-Space, ordered-out, and ghost AX
        // elements without hiding windows explicitly marked as minimized.
        let options: CGWindowListOption = [
            .optionAll,
            .excludeDesktopElements,
        ]
        guard let windowInfo = CGWindowListCopyWindowInfo(
            options,
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return nil
        }

        var visibleWindowIdentifiers: [pid_t: Set<CGWindowID>] = [:]
        var windowOwnerProcessIdentifiers: Set<pid_t> = []
        for window in windowInfo {
            guard
                window[kCGWindowLayer as String] as? Int == 0,
                let processIdentifier = window[
                    kCGWindowOwnerPID as String
                ] as? Int,
                let windowIdentifier = window[
                    kCGWindowNumber as String
                ] as? CGWindowID
            else {
                continue
            }

            let owner = pid_t(processIdentifier)
            windowOwnerProcessIdentifiers.insert(owner)
            if window[kCGWindowIsOnscreen as String] as? Bool == true {
                visibleWindowIdentifiers[owner, default: []].insert(windowIdentifier)
            }
        }
        return WindowQueryPlan(
            visibleWindowIdentifiers: visibleWindowIdentifiers,
            windowOwnerProcessIdentifiers: windowOwnerProcessIdentifiers
        )
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
        var hasIncompleteWindowReads = false
        for element in elements {
            guard !Task.isCancelled,
                  DispatchTime.now() < deadline else {
                // The budget expired mid-scan, so the windows left unread stay
                // unaccounted for rather than counting as absent.
                hasIncompleteWindowReads = true
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
                hasIncompleteWindowReads = true
                continue
            }

            if AXElementReader.containsTransientError(in: windowValues) {
                hasIncompleteWindowReads = true
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
            hasIncompleteWindowReads: hasIncompleteWindowReads,
            windows: windows
        )
    }

}
