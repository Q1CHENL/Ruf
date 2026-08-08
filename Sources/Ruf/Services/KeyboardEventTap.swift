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
    let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
    let modifiers = keyboardModifiers(from: flags)
    let shouldReadCharacters = type == .keyDown
        && !isRepeat
        && modifiers == [.command]
        && keyCode != KeyboardKeyCode.ansiN
        && keyCode != KeyboardKeyCode.ansiQ
        && MainActor.assumeIsolated { controller.isCycling }
    let characters = shouldReadCharacters ? keyboardCharacters(from: event) : nil
    let consumed = MainActor.assumeIsolated {
        controller.handle(
            type: type,
            keyCode: keyCode,
            modifiers: modifiers,
            isRepeat: isRepeat,
            characters: characters
        )
    }

    return consumed ? nil : Unmanaged.passUnretained(event)
}

private func keyboardCharacters(from event: CGEvent) -> String? {
    var buffer = [UniChar](repeating: 0, count: 4)
    var length = 0

    buffer.withUnsafeMutableBufferPointer { characters in
        event.keyboardGetUnicodeString(
            maxStringLength: characters.count,
            actualStringLength: &length,
            unicodeString: characters.baseAddress
        )
    }

    guard length > 0 else {
        return nil
    }

    return String(
        utf16CodeUnits: buffer,
        count: min(length, buffer.count)
    )
}

private func keyboardModifiers(
    from flags: CGEventFlags
) -> KeyboardModifiers {
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
    return modifiers
}

@MainActor
final class KeyboardEventTap {
    private static let pendingGestureTimeout: Duration = .seconds(2)

    private let commandHandler: (KeyboardCommand) -> Void

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var inputSession = KeyboardInputSession()
    private var pendingGestureTimeoutTask: Task<Void, Never>?
    private var capturesCommandTab: Bool
    private var capturesWindowMovement: Bool

    fileprivate var isCycling: Bool {
        inputSession.isCycling
    }

    var isRunning: Bool {
        guard let eventTap else {
            return false
        }

        return CGEvent.tapIsEnabled(tap: eventTap)
    }

    init(
        capturesCommandTab: Bool,
        capturesWindowMovement: Bool,
        commandHandler: @escaping (KeyboardCommand) -> Void
    ) {
        self.capturesCommandTab = capturesCommandTab
        self.capturesWindowMovement = capturesWindowMovement
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
        pendingGestureTimeoutTask?.cancel()
        pendingGestureTimeoutTask = nil
        inputSession.reset()
    }

    func setCaptureState(
        capturesCommandTab: Bool,
        capturesWindowMovement: Bool
    ) {
        let commandTabChanged = self.capturesCommandTab != capturesCommandTab
        let windowMovementChanged = self.capturesWindowMovement
            != capturesWindowMovement
        guard commandTabChanged || windowMovementChanged else {
            return
        }

        if commandTabChanged {
            resetInputSession()
        }
        self.capturesCommandTab = capturesCommandTab
        self.capturesWindowMovement = capturesWindowMovement
    }

    private func tearDownEventTap() {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }

        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
        }

        runLoopSource = nil
        eventTap = nil
    }

    fileprivate func handle(
        type: CGEventType,
        keyCode: Int64,
        modifiers: KeyboardModifiers,
        isRepeat: Bool,
        characters: String?
    ) -> Bool {
        let previousGestureToken = inputSession.pendingSwitcherGestureToken

        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }

            if let action = inputSession.interrupt() {
                enqueue(action)
            }
            synchronizePendingGestureTimeout(previousToken: previousGestureToken)
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

        let decision = inputSession.interpret(
            KeyboardInput(
                kind: kind,
                keyCode: keyCode,
                modifiers: modifiers,
                isRepeat: isRepeat,
                characters: characters
            ),
            capturesCommandTab: capturesCommandTab,
            capturesWindowMovement: capturesWindowMovement
        )
        synchronizePendingGestureTimeout(previousToken: previousGestureToken)

        if let command = decision.command {
            enqueue(command)
        }

        return decision.isConsumed
    }

    private func synchronizePendingGestureTimeout(previousToken: UInt64?) {
        guard let token = inputSession.pendingSwitcherGestureToken else {
            pendingGestureTimeoutTask?.cancel()
            pendingGestureTimeoutTask = nil
            return
        }

        // A gesture replaced mid-flight is a new one and earns a full window,
        // so only an unchanged token keeps the timer already running.
        guard token != previousToken else {
            return
        }

        pendingGestureTimeoutTask?.cancel()
        pendingGestureTimeoutTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: Self.pendingGestureTimeout)
            } catch {
                return
            }

            guard let self else {
                return
            }

            pendingGestureTimeoutTask = nil
            if let command = inputSession.cancelPendingSwitcherGesture() {
                enqueue(command)
            }
        }
    }

    private func enqueue(_ command: KeyboardCommand) {
        DispatchQueue.main.async { [weak self] in
            self?.commandHandler(command)
        }
    }
}
