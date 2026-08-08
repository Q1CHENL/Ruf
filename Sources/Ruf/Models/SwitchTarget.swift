import RufCore

enum SwitchTargetKind {
    case application
    case applicationWindow(ApplicationWindow)
    case openRufSettings(softwareUpdateVersion: String?)
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

    var showsSoftwareUpdateIndicator: Bool {
        if case let .openRufSettings(softwareUpdateVersion) = kind {
            return softwareUpdateVersion != nil
        }

        return false
    }

    private var softwareUpdateVersion: String? {
        if case let .openRufSettings(softwareUpdateVersion) = kind {
            return softwareUpdateVersion
        }

        return nil
    }

    var participatesInInitialSelection: Bool {
        if case .openRufSettings = kind {
            return false
        }

        return true
    }

    var accessibilityLabel: String {
        let targetLabel: String

        switch kind {
        case .application, .applicationWindow:
            targetLabel = item.name
        case .openRufSettings:
            targetLabel = "Open Ruf Settings"
        case let .window(window):
            targetLabel = window.title.map { "\(item.name), \($0)" } ?? item.name
        case .reopenApplication:
            targetLabel = "Reopen \(item.name)"
        }

        var details = [targetLabel]
        if showsSoftwareUpdateIndicator,
           let softwareUpdateVersion {
            details.append("Ruf update \(softwareUpdateVersion) available")
        }
        if let dockBadge {
            details.append("Dock badge \(dockBadge.accessibilityLabel)")
        }

        return details.joined(separator: ", ")
    }
}
