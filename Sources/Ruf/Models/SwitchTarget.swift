import RufCore

enum SwitchTargetKind {
    case application
    case window(ApplicationWindow)
    case reopenApplication
}

@MainActor
struct SwitchTarget {
    let item: ApplicationItem
    let kind: SwitchTargetKind
    let dockBadge: DockBadge?

    var title: String {
        guard case let .window(window) = kind else {
            return item.name
        }

        return window.title
    }

    var showsWindowTitle: Bool {
        if case .window = kind {
            return true
        }

        return false
    }

    var showsReopenBadge: Bool {
        if case .reopenApplication = kind {
            return true
        }

        return false
    }

    var accessibilityLabel: String {
        let targetLabel: String

        switch kind {
        case .application:
            targetLabel = item.name
        case let .window(window):
            targetLabel = "\(item.name), \(window.title)"
        case .reopenApplication:
            targetLabel = "Reopen \(item.name)"
        }

        guard let dockBadge else {
            return targetLabel
        }

        return "\(targetLabel), Dock badge \(dockBadge.accessibilityLabel)"
    }
}
