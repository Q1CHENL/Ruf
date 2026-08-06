import RufCore

enum SwitchTargetKind {
    case application
    case applicationWindow(ApplicationWindow)
    case window(ApplicationWindow)
    case reopenApplication
}

@MainActor
struct SwitchTarget {
    let item: ApplicationItem
    let kind: SwitchTargetKind
    let dockBadge: DockBadge?

    var title: String {
        guard case let .window(window) = kind,
              let windowTitle = window.title else {
            return item.name
        }

        return windowTitle
    }

    // A window Ruf could not read a title for is labelled with its
    // application's name, which is laid out the same way an application cell is.
    var showsWindowTitle: Bool {
        if case let .window(window) = kind {
            return window.title != nil
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
        case .application, .applicationWindow:
            targetLabel = item.name
        case let .window(window):
            targetLabel = window.title.map { "\(item.name), \($0)" } ?? item.name
        case .reopenApplication:
            targetLabel = "Reopen \(item.name)"
        }

        guard let dockBadge else {
            return targetLabel
        }

        return "\(targetLabel), Dock badge \(dockBadge.accessibilityLabel)"
    }
}
