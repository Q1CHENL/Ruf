import ApplicationServices
import CoreGraphics
import Darwin

enum AXWindowIdentifierResolver {
    private typealias GetWindowFunction = @convention(c) (
        AXUIElement,
        UnsafeMutablePointer<CGWindowID>
    ) -> AXError

    private static let getWindow: GetWindowFunction? = {
        // Resolve this private Accessibility SPI at runtime so its removal
        // degrades to app-level targets instead of preventing Ruf from launching.
        guard
            let processHandle = dlopen(nil, RTLD_LAZY),
            let symbol = dlsym(processHandle, "_AXUIElementGetWindow")
        else {
            return nil
        }

        return unsafeBitCast(symbol, to: GetWindowFunction.self)
    }()

    static func identifier(for element: AXUIElement) -> CGWindowID? {
        guard let getWindow else {
            return nil
        }

        var identifier = kCGNullWindowID
        guard
            getWindow(element, &identifier) == .success,
            identifier != kCGNullWindowID
        else {
            return nil
        }

        return identifier
    }
}
