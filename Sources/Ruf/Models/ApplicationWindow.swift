import ApplicationServices

// Discovery completes before the handle crosses to MainActor, so Ruf never
// accesses the same AXUIElement concurrently.
struct ApplicationWindow: @unchecked Sendable {
    let element: AXUIElement
    // Chromium keeps a partial Accessibility tree until an assistive client
    // touches it, and reports no title for windows meanwhile. A window without
    // a readable title is still a window worth switching to, so the title is
    // for display only and callers fall back to the application's name.
    let title: String?
    let isMinimized: Bool
}

enum ApplicationWindowState: Sendable {
    case singleWindow(ApplicationWindow)
    case windowless
    case windows([ApplicationWindow])
}
