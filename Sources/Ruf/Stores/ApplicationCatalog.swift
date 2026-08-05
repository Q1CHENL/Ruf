import AppKit
import RufCore

@MainActor
final class ApplicationCatalog: NSObject {
    private static let recentApplicationsKey = "recentApplicationBundleIdentifiers"

    private let workspace = NSWorkspace.shared
    private var recentApplications: RecentApplicationList

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

    func snapshot() async -> [SwitchTarget] {
        let applications = applicationSnapshot()
        let windowStates = await ApplicationWindowService.states(
            for: applications.map(\.application.processIdentifier)
        )

        return applications.flatMap { item -> [SwitchTarget] in
            switch windowStates[item.application.processIdentifier] {
            case .windowless?:
                return [
                    SwitchTarget(item: item, kind: .reopenApplication),
                ]
            case let .windows(windows)?:
                return windows.map { window in
                    SwitchTarget(item: item, kind: .window(window))
                }
            case nil:
                return [SwitchTarget(item: item, kind: .application)]
            }
        }
    }

    private func applicationSnapshot() -> [ApplicationItem] {
        if let frontmostApplication = workspace.frontmostApplication {
            recordActivation(frontmostApplication)
        }

        var itemsByBundleIdentifier: [String: ApplicationItem] = [:]

        for application in workspace.runningApplications {
            guard
                application.activationPolicy == .regular,
                !application.isTerminated,
                let bundleIdentifier = application.bundleIdentifier,
                let name = application.localizedName,
                let icon = ApplicationIconResolver.icon(for: application)
            else {
                continue
            }

            let item = ApplicationItem(
                application: application,
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

        recordActivation(application)
    }

    private func recordActivation(_ application: NSRunningApplication) {
        guard
            application.activationPolicy == .regular,
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
