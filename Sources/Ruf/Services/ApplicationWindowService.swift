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
        let resolutions: [pid_t: ApplicationWindowResolution<ApplicationWindow>]

        /// An application whose query never ran or did not finish is offered
        /// as a whole.
        func resolution(
            for processIdentifier: pid_t
        ) -> ApplicationWindowResolution<ApplicationWindow> {
            resolutions[processIdentifier] ?? .application
        }

        func includesApplication(
            _ processIdentifier: pid_t,
            policy: ApplicationDiscoveryPolicy
        ) -> Bool {
            policy.shouldInclude(
                hasSwitchableWindows: resolution(for: processIdentifier)
                    .hasSwitchableWindows
            )
        }
    }

    private struct ApplicationWindowsQuery {
        let observations: [ApplicationWindowObservation<ApplicationWindow>]
        let hasUnreadWindows: Bool
    }

    private struct WindowResolutionQueryResult: Sendable {
        let processIdentifier: pid_t
        let resolution: ApplicationWindowResolution<ApplicationWindow>
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
            return Snapshot(resolutions: [:])
        }

        let windowListSpan = PerformanceLog.begin("ax.windowList")
        let plan = windowQueryPlan()
        PerformanceLog.end(windowListSpan)

        guard let plan else {
            return Snapshot(resolutions: [:])
        }
        guard AccessibilityPermission.isGranted else {
            return Snapshot(resolutions: [:])
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
        let queryCandidate: @Sendable (Candidate) -> WindowResolutionQueryResult = { candidate in
            queryResolution(
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

        let resolutions = await withTaskGroup(
            of: WindowResolutionQueryResult.self
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

            var resolutions: [pid_t: ApplicationWindowResolution<ApplicationWindow>] = [:]
            var resolvedCount = 0

            while let result = await group.next() {
                guard !Task.isCancelled else {
                    group.cancelAll()
                    continue
                }

                resolutions[result.processIdentifier] = result.resolution
                switch result.resolution {
                case .application:
                    break
                case .singleWindow, .windowless, .windows:
                    resolvedCount += 1
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

            // A candidate that was never dispatched, or that resolved to the
            // application, is one the switcher silently degrades to an
            // app-level tile. That ratio is the signal the budget is too tight,
            // not the elapsed time on its own.
            PerformanceLog.end(
                querySpan,
                "candidates=\(queryCandidates.count) "
                    + "dispatched=\(dispatchedCount) "
                    + "resolved=\(resolvedCount) "
                    + "budgetExpired=\(DispatchTime.now() >= deadline)"
            )
            return resolutions
        }
        return Snapshot(resolutions: resolutions)
    }

    private static func queryResolution(
        for processIdentifier: pid_t,
        isApplicationHidden: Bool,
        otherSpaceWindowEvidence: OtherSpaceWindowEvidence,
        plan: WindowQueryPlan,
        deadline: DispatchTime
    ) -> WindowResolutionQueryResult {
        guard !Task.isCancelled,
              DispatchTime.now() < deadline,
              let query = windows(
                  for: processIdentifier,
                  plan: plan,
                  deadline: deadline
              ) else {
            return WindowResolutionQueryResult(
                processIdentifier: processIdentifier,
                resolution: .application
            )
        }

        return WindowResolutionQueryResult(
            processIdentifier: processIdentifier,
            resolution: .resolve(
                query.observations,
                hasUnreadWindows: query.hasUnreadWindows,
                hasVisibleWindows: plan.hasVisibleWindows(
                    for: processIdentifier
                ),
                isApplicationHidden: isApplicationHidden,
                otherSpaceWindowEvidence: otherSpaceWindowEvidence
            )
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
        var observations: [ApplicationWindowObservation<ApplicationWindow>] = []
        var hasUnreadWindows = false
        for element in elements {
            guard !Task.isCancelled,
                  DispatchTime.now() < deadline else {
                // The budget expired mid-scan, so the windows left unread stay
                // unaccounted for rather than counting as absent.
                hasUnreadWindows = true
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
                hasUnreadWindows = true
                continue
            }

            if AXElementReader.containsTransientError(in: windowValues) {
                hasUnreadWindows = true
            }

            let subrole: String? = AXElementReader.decoded(windowValues[0])
            let isMinimized: Bool = AXElementReader.decoded(windowValues[1]) ?? false
            let title: String? = AXElementReader.decoded(windowValues[2])
            let isSwitchable = subrole == kAXStandardWindowSubrole
                || subrole == kAXDialogSubrole
            let trimmedTitle = title?.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            let displayTitle = trimmedTitle?.isEmpty == false
                ? trimmedTitle
                : nil

            // Only a switchable window that is not minimized is worth the
            // identifier lookup; nothing else depends on its visibility.
            let windowIdentifier = isSwitchable && !isMinimized
                ? AXWindowIdentifierResolver.identifier(for: element)
                : nil
            observations.append(
                ApplicationWindowObservation(
                    window: ApplicationWindow(
                        element: element,
                        title: displayTitle,
                        isMinimized: isMinimized
                    ),
                    isSwitchable: isSwitchable,
                    isMinimized: isMinimized,
                    isFocused: focusedWindow.map {
                        CFEqual($0, element)
                    } ?? false,
                    visibility: plan.visibility(
                        ofWindow: windowIdentifier,
                        ownedBy: processIdentifier
                    )
                )
            )
        }

        return ApplicationWindowsQuery(
            observations: observations,
            hasUnreadWindows: hasUnreadWindows
        )
    }

}
