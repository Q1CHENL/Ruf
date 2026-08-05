import ApplicationServices

// Discovery completes before the handle crosses to MainActor, so Ruf never
// accesses the same AXUIElement concurrently.
struct ApplicationWindow: @unchecked Sendable {
    let element: AXUIElement
    let title: String
    let isMinimized: Bool
}

enum ApplicationWindowState: Sendable {
    case windowless
    case windows([ApplicationWindow])
}
