import AppKit
import RufCore
import Observation

@MainActor
@Observable
final class SwitcherModel {
    private(set) var applications: [ApplicationItem] = []
    private var session = SwitcherSession()

    var selectedIndex: Int? {
        session.selectedIndex
    }

    var isPresented: Bool {
        session.isPresented
    }

    var navigation: GridNavigation {
        session.navigation
    }

    func begin(with applications: [ApplicationItem], backwards: Bool) {
        self.applications = applications
        session.begin(itemCount: applications.count, backwards: backwards)
    }

    func move(_ move: GridMove) {
        session.move(move)
    }

    func select(_ index: Int) {
        session.select(index)
    }

    func finish() -> NSRunningApplication? {
        let selectedApplication = session.finish().map { index in
            applications[index].application
        }

        applications = []
        return selectedApplication
    }

    func cancel() {
        session.cancel()
        applications = []
    }
}
