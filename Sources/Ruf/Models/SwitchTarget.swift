@MainActor
struct SwitchTarget {
    let item: ApplicationItem
    let window: ApplicationWindow?

    var title: String {
        window?.title ?? item.name
    }

    var accessibilityLabel: String {
        guard let window else {
            return item.name
        }

        return "\(item.name), \(window.title)"
    }
}
