import CoreGraphics
import RufCore

private func keyboardEventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else {
        return Unmanaged.passUnretained(event)
    }

    let controller = Unmanaged<KeyboardEventTap>.fromOpaque(userInfo).takeUnretainedValue()
    let flags = event.flags
    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
    let consumed = MainActor.assumeIsolated {
        controller.handle(type: type, flags: flags, keyCode: keyCode)
    }

    return consumed ? nil : Unmanaged.passUnretained(event)
}

@MainActor
final class KeyboardEventTap {
    private let commandHandler: (SwitcherAction) -> Void

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var inputSession = KeyboardInputSession()

    var isRunning: Bool {
        guard let eventTap else {
            return false
        }

        return CGEvent.tapIsEnabled(tap: eventTap)
    }

    init(commandHandler: @escaping (SwitcherAction) -> Void) {
        self.commandHandler = commandHandler
    }

    @discardableResult
    func start() -> Bool {
        if let eventTap, CFMachPortIsValid(eventTap) {
            CGEvent.tapEnable(tap: eventTap, enable: true)
            return CGEvent.tapIsEnabled(tap: eventTap)
        }

        tearDownEventTap()

        let eventTypes: [CGEventType] = [
            .keyDown,
            .keyUp,
            .flagsChanged,
        ]
        let eventMask = eventTypes.reduce(CGEventMask(0)) { mask, type in
            mask | (CGEventMask(1) << type.rawValue)
        }

        guard let eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: keyboardEventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)

        self.eventTap = eventTap
        runLoopSource = source
        return true
    }

    func stop() {
        resetInputSession()
        tearDownEventTap()
    }

    func resetInputSession() {
        inputSession.reset()
    }

    private func tearDownEventTap() {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }

        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }

        runLoopSource = nil
        eventTap = nil
    }

    fileprivate func handle(
        type: CGEventType,
        flags: CGEventFlags,
        keyCode: Int64
    ) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }

            if let action = inputSession.interrupt() {
                enqueue(action)
            }
            return false
        }

        let kind: KeyboardEventKind
        switch type {
        case .keyDown:
            kind = .keyDown
        case .keyUp:
            kind = .keyUp
        case .flagsChanged:
            kind = .flagsChanged
        default:
            return false
        }

        var modifiers: KeyboardModifiers = []
        if flags.contains(.maskCommand) {
            modifiers.insert(.command)
        }
        if flags.contains(.maskShift) {
            modifiers.insert(.shift)
        }
        if flags.contains(.maskControl) {
            modifiers.insert(.control)
        }
        if flags.contains(.maskAlternate) {
            modifiers.insert(.option)
        }

        let decision = inputSession.interpret(
            KeyboardInput(kind: kind, keyCode: keyCode, modifiers: modifiers)
        )

        if let action = decision.action {
            enqueue(action)
        }

        return decision.isConsumed
    }

    private func enqueue(_ action: SwitcherAction) {
        DispatchQueue.main.async { [weak self] in
            self?.commandHandler(action)
        }
    }
}
