import AppKit
import RufCore

@MainActor
final class ApplicationCatalog: NSObject {
    struct Snapshot {
        let targets: [SwitchTarget]
        /// The application the user is switching away from. It can have no
        /// target, for example when Ruf itself is frontmost.
        let currentBundleIdentifier: String?
    }

    private static let recentApplicationsKey = "recentApplicationBundleIdentifiers"

    private let workspace = NSWorkspace.shared
    private var recentApplications: RecentApplicationList
    /// An application Ruf asked to activate that macOS has not reported
    /// active yet. Activation is asynchronous, so until then this
    /// application, not the one still frontmost, is current.
    private var requestedActivation: NSRunningApplication?

    override init() {
        recentApplications = RecentApplicationList(
            identifiers: UserDefaults.standard.stringArray(
                forKey: Self.recentApplicationsKey
            ) ?? []
        )

        super.init()

        if let frontmostApplication = workspace.frontmostApplication {
            recordActivation(frontmostApplication)
        }

        workspace.notificationCenter.addObserver(
            self,
            selector: #selector(applicationDidActivate(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
    }

    /// Records `application` as the most recent one as soon as Ruf asks
    /// macOS to activate it, so a gesture that starts before the activation
    /// lands still switches back to the application the user just left.
    func recordRequestedActivation(of application: NSRunningApplication) {
        requestedActivation = application
        recordActivation(application)
    }

    func snapshot(
        includesRufSettingsTarget: Bool = false,
        rufSoftwareUpdateVersion: String? = nil
    ) async -> Snapshot {
        let snapshotSpan = PerformanceLog.begin("catalog.snapshot")
        let currentApplication = resolveCurrentApplication()
        if let currentApplication {
            recordActivation(currentApplication)
        }

        let applicationSpan = PerformanceLog.begin("catalog.applications")
        let applications = applicationSnapshot()
        PerformanceLog.end(applicationSpan, "apps=\(applications.count)")

        async let windowSnapshotQuery = ApplicationWindowService.snapshot(
            for: applications.map {
                ApplicationWindowService.Candidate(
                    processIdentifier: $0.application.processIdentifier,
                    policy: $0.discoveryPolicy,
                    isHidden: $0.application.isHidden
                )
            }
        )
        async let dockBadgesQuery = DockBadgeService.badges()
        let (windowSnapshot, dockBadges) = await (
            windowSnapshotQuery,
            dockBadgesQuery
        )

        var targets = applications.flatMap { item -> [SwitchTarget] in
            guard windowSnapshot.includesApplication(
                item.application.processIdentifier,
                policy: item.discoveryPolicy
            ) else {
                return []
            }
            let dockBadge = item.application.bundleURL.flatMap {
                dockBadges[$0.standardizedFileURL]
            }

            let kinds: [SwitchTargetKind]
            switch windowSnapshot.resolution(
                for: item.application.processIdentifier
            ) {
            case .application:
                kinds = [.application]
            case let .singleWindow(window):
                kinds = [.applicationWindow(window)]
            case .windowless:
                kinds = [.reopenApplication]
            case let .windows(windows):
                kinds = windows.map(SwitchTargetKind.window)
            }
            return kinds.map { kind in
                SwitchTarget(item: item, kind: kind, dockBadge: dockBadge)
            }
        }

        if includesRufSettingsTarget,
           let settingsTarget = rufSettingsTarget(
               softwareUpdateVersion: rufSoftwareUpdateVersion
           ) {
            targets.append(settingsTarget)
        }

        PerformanceLog.end(
            snapshotSpan,
            "apps=\(applications.count) badges=\(dockBadges.count) "
                + "targets=\(targets.count)"
        )
        return Snapshot(
            targets: targets,
            currentBundleIdentifier: currentApplication?.bundleIdentifier
        )
    }

    private func resolveCurrentApplication() -> NSRunningApplication? {
        let frontmostApplication = workspace.frontmostApplication
        if let requestedActivation,
           requestedActivation.processIdentifier
            != frontmostApplication?.processIdentifier {
            return requestedActivation
        }

        requestedActivation = nil
        return frontmostApplication
    }

    private func rufSettingsTarget(
        softwareUpdateVersion: String?
    ) -> SwitchTarget? {
        let application = NSRunningApplication.current
        guard
            !application.isTerminated,
            let bundleIdentifier = application.bundleIdentifier,
            let name = application.localizedName,
            let icon = ApplicationIconResolver.icon(for: application)
        else {
            return nil
        }

        return SwitchTarget(
            item: ApplicationItem(
                application: application,
                discoveryPolicy: .excluded,
                bundleIdentifier: bundleIdentifier,
                name: name,
                icon: icon
            ),
            kind: .openRufSettings(
                softwareUpdateVersion: softwareUpdateVersion
            ),
            dockBadge: nil
        )
    }

    private func applicationSnapshot() -> [ApplicationItem] {
        let runningSpan = PerformanceLog.begin("catalog.runningApps")
        let runningApplications = workspace.runningApplications
        PerformanceLog.end(runningSpan, "running=\(runningApplications.count)")

        let filterSpan = PerformanceLog.begin("catalog.filter")
        var itemsByBundleIdentifier: [String: ApplicationItem] = [:]

        for application in runningApplications {
            let discoveryPolicy = ApplicationDiscoveryPolicy(application: application)
            guard
                discoveryPolicy.isCandidate,
                !application.isTerminated,
                let bundleIdentifier = application.bundleIdentifier,
                let name = application.localizedName,
                let icon = ApplicationIconResolver.icon(for: application)
            else {
                continue
            }

            let item = ApplicationItem(
                application: application,
                discoveryPolicy: discoveryPolicy,
                bundleIdentifier: bundleIdentifier,
                name: name,
                icon: icon
            )

            if let existingItem = itemsByBundleIdentifier[bundleIdentifier],
               !shouldPrefer(item, over: existingItem) {
                continue
            }

            itemsByBundleIdentifier[bundleIdentifier] = item
        }

        PerformanceLog.end(filterSpan, "kept=\(itemsByBundleIdentifier.count)")

        let sortSpan = PerformanceLog.begin("catalog.sort")
        defer {
            PerformanceLog.end(sortSpan)
        }

        let recentRanks = recentApplications.identifiers.enumerated().reduce(
            into: [String: Int]()
        ) { ranks, entry in
            ranks[entry.element] = entry.offset
        }

        return itemsByBundleIdentifier.values.sorted { left, right in
            let leftRank = recentRanks[left.bundleIdentifier] ?? Int.max
            let rightRank = recentRanks[right.bundleIdentifier] ?? Int.max

            if leftRank != rightRank {
                return leftRank < rightRank
            }

            return left.name.localizedStandardCompare(right.name) == .orderedAscending
        }
    }

    @objc
    private func applicationDidActivate(_ notification: Notification) {
        guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
            as? NSRunningApplication
        else {
            return
        }

        requestedActivation = nil
        recordActivation(application)
    }

    private func recordActivation(_ application: NSRunningApplication) {
        guard
            ApplicationDiscoveryPolicy(application: application).isCandidate,
            let bundleIdentifier = application.bundleIdentifier,
            recentApplications.identifiers.first != bundleIdentifier
        else {
            return
        }

        recentApplications.record(bundleIdentifier)

        UserDefaults.standard.set(
            recentApplications.identifiers,
            forKey: Self.recentApplicationsKey
        )
    }

    private func shouldPrefer(
        _ candidate: ApplicationItem,
        over existing: ApplicationItem
    ) -> Bool {
        let candidateIsActive = candidate.application.isActive
        let existingIsActive = existing.application.isActive

        if candidateIsActive != existingIsActive {
            return candidateIsActive
        }

        return candidate.application.processIdentifier
            < existing.application.processIdentifier
    }
}
