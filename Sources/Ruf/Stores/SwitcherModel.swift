import RufCore
import Observation

@MainActor
@Observable
final class SwitcherModel {
    private(set) var targets: [SwitchTarget] = []
    private(set) var applicationResourceUsage = ApplicationResourceUsage(
        cpuPercentage: nil,
        memoryBytes: nil,
        runningDuration: nil
    )
    private var session = SwitcherSession()

    var selectedIndex: Int? {
        session.selectedIndex
    }

    var isPresented: Bool {
        session.isPresented
    }

    var showsApplicationResourceUsage: Bool {
        session.showsApplicationResourceUsage
    }

    var selectedTarget: SwitchTarget? {
        guard let selectedIndex,
              targets.indices.contains(selectedIndex) else {
            return nil
        }

        return targets[selectedIndex]
    }

    var applicationResourceUsageText: String {
        ApplicationResourceUsageFormatter.string(
            cpuPercentage: applicationResourceUsage.cpuPercentage,
            memoryBytes: applicationResourceUsage.memoryBytes,
            runningDuration: applicationResourceUsage.runningDuration
        )
    }

    func begin(
        with targets: [SwitchTarget],
        backwards: Bool,
        showsApplicationResourceUsage: Bool
    ) {
        clearApplicationResourceUsage()
        self.targets = targets
        let initialSelectionTargetCount = targets.prefix {
            $0.participatesInInitialSelection
        }.count
        session.begin(
            groupIdentifiers: targets.map(\.item.bundleIdentifier),
            initialSelectionTargetCount: initialSelectionTargetCount,
            backwards: backwards,
            showsApplicationResourceUsage: showsApplicationResourceUsage
        )
    }

    func move(_ move: GridMove) {
        session.move(move)
    }

    func select(_ index: Int) {
        session.select(index)
    }

    func toggleApplicationResourceUsage() -> Bool {
        session.toggleApplicationResourceUsage()
    }

    func updateApplicationResourceUsage(
        _ usage: ApplicationResourceUsage
    ) {
        applicationResourceUsage = usage
    }

    func clearApplicationResourceUsage() {
        applicationResourceUsage = ApplicationResourceUsage(
            cpuPercentage: nil,
            memoryBytes: nil,
            runningDuration: nil
        )
    }

    func finish() -> SwitchTarget? {
        let selectedTarget = session.finish().map { index in
            targets[index]
        }

        targets = []
        clearApplicationResourceUsage()
        return selectedTarget
    }

    func cancel() {
        session.cancel()
        targets = []
        clearApplicationResourceUsage()
    }
}
