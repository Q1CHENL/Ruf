import RufCore
import Observation

@MainActor
@Observable
final class SwitcherModel {
    private(set) var targets: [SwitchTarget] = []
    private var session = SwitcherSession()

    var selectedIndex: Int? {
        session.selectedIndex
    }

    var isPresented: Bool {
        session.isPresented
    }

    func begin(with targets: [SwitchTarget], backwards: Bool) {
        self.targets = targets
        let initialSelectionTargetCount = targets.prefix {
            $0.participatesInInitialSelection
        }.count
        session.begin(
            groupIdentifiers: targets.map(\.item.bundleIdentifier),
            initialSelectionTargetCount: initialSelectionTargetCount,
            backwards: backwards
        )
    }

    func move(_ move: GridMove) {
        session.move(move)
    }

    func select(_ index: Int) {
        session.select(index)
    }

    func finish() -> SwitchTarget? {
        let selectedTarget = session.finish().map { index in
            targets[index]
        }

        targets = []
        return selectedTarget
    }

    func cancel() {
        session.cancel()
        targets = []
    }
}
