enum SwitchTargetKind {
    case application
    case window(ApplicationWindow)
    case reopenApplication
}

@MainActor
struct SwitchTarget {
    let item: ApplicationItem
    let kind: SwitchTargetKind

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
        switch kind {
        case .application:
            return item.name
        case let .window(window):
            return "\(item.name), \(window.title)"
        case .reopenApplication:
            return "Reopen \(item.name)"
        }
    }
}
