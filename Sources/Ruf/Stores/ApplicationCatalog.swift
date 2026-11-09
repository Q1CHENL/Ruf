import AppKit
import RufCore

@MainActor
final class ApplicationCatalog: NSObject {
    struct Snapshot {
        let targets: [SwitchTarget]
        /// The application the user is switching away from. It can have no
        /// target, for example when Ruf itself is frontmost.
        let currentApplicationIdentifier: String?
    }

    // The key predates executable paths among the identifiers. It stays so
    // the recency order saved by earlier versions keeps loading.
    private static let recentApplicationsKey = "recentApplicationBundleIdentifiers"

    private let workspace = NSWorkspace.shared
    private var recentApplications: RecentApplicationList<String>
    /// The order the user last activated processes in, which orders the
    /// instances of one application. Process identifiers do not outlive the
    /// processes, so this is not persisted.
    private var recentProcesses = RecentApplicationList<pid_t>()
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
        let instances = applicationInstances()
        PerformanceLog.end(applicationSpan, "apps=\(instances.count)")

        let candidates = instances.map {
            ApplicationWindowService.Candidate(
                processIdentifier: $0.processIdentifier,
                policy: $0.policy,
                isHidden: $0.item.application.isHidden
            )
        }
        async let resolutionsQuery = ApplicationWindowService.resolutions(
            for: candidates
        )
        async let dockBadgesQuery = DockBadgeService.badges()
        let (resolutions, dockBadges) = await (
            resolutionsQuery,
            dockBadgesQuery
        )

        var targets = ApplicationTargetPlan.offers(
            for: instances,
            resolutions: resolutions
        ).flatMap { offer -> [SwitchTarget] in
            let item = offer.item
            let dockBadge = item.application.bundleURL.flatMap {
                dockBadges[$0.standardizedFileURL]
            }

            let kinds: [SwitchTargetKind]
            switch offer.resolution {
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
            "apps=\(instances.count) badges=\(dockBadges.count) "
                + "targets=\(targets.count)"
        )
        return Snapshot(
            targets: targets,
            currentApplicationIdentifier: currentApplication?.applicationIdentifier
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
            let applicationIdentifier = application.applicationIdentifier,
            let name = application.localizedName
        else {
            return nil
        }

        return SwitchTarget(
            item: ApplicationItem(
                application: application,
                applicationIdentifier: applicationIdentifier,
                name: name,
                icon: ApplicationIconResolver.icon(for: application)
            ),
            kind: .openRufSettings(
                softwareUpdateVersion: softwareUpdateVersion
            ),
            dockBadge: nil
        )
    }

    /// Every process the switcher may offer, in switcher order. Instances of
    /// one application are kept apart so each one's windows stay reachable.
    private func applicationInstances() -> [ApplicationInstance<ApplicationItem>] {
        let runningSpan = PerformanceLog.begin("catalog.runningApps")
        let runningApplications = workspace.runningApplications
        PerformanceLog.end(runningSpan, "running=\(runningApplications.count)")

        let filterSpan = PerformanceLog.begin("catalog.filter")
        let instances = runningApplications.compactMap {
            application -> ApplicationInstance<ApplicationItem>? in
            let discoveryPolicy = ApplicationDiscoveryPolicy(application: application)
            guard
                discoveryPolicy.isCandidate,
                !application.isTerminated,
                let applicationIdentifier = application.applicationIdentifier,
                let name = application.localizedName
            else {
                return nil
            }

            return ApplicationInstance(
                item: ApplicationItem(
                    application: application,
                    applicationIdentifier: applicationIdentifier,
                    name: name,
                    icon: ApplicationIconResolver.icon(for: application)
                ),
                applicationIdentifier: applicationIdentifier,
                name: name,
                processIdentifier: application.processIdentifier,
                policy: discoveryPolicy
            )
        }
        PerformanceLog.end(filterSpan, "kept=\(instances.count)")

        let sortSpan = PerformanceLog.begin("catalog.sort")
        defer {
            PerformanceLog.end(sortSpan)
        }

        // The window query runs in this order, so the applications the user
        // is most likely to pick are resolved first when its budget is tight.
        return ApplicationTargetPlan.ordered(
            instances,
            recentApplicationIdentifiers: recentApplications.identifiers,
            recentProcessIdentifiers: recentProcesses.identifiers
        )
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
            let applicationIdentifier = application.applicationIdentifier
        else {
            return
        }

        recentProcesses.record(application.processIdentifier)
        guard recentApplications.identifiers.first != applicationIdentifier else {
            return
        }

        recentApplications.record(applicationIdentifier)

        UserDefaults.standard.set(
            recentApplications.identifiers,
            forKey: Self.recentApplicationsKey
        )
    }
}
