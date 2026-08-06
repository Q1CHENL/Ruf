public enum KeyboardEventKind: Sendable {
    case keyDown
    case keyUp
    case flagsChanged
}

public struct KeyboardModifiers: OptionSet, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let command = Self(rawValue: 1 << 0)
    public static let shift = Self(rawValue: 1 << 1)
    public static let control = Self(rawValue: 1 << 2)
    public static let option = Self(rawValue: 1 << 3)
}

public enum KeyboardKeyCode {
    public static let ansiN: Int64 = 45
    public static let ansiQ: Int64 = 12
    public static let tab: Int64 = 48
    public static let returnKey: Int64 = 36
    public static let keypadEnter: Int64 = 76
    public static let escape: Int64 = 53
    public static let leftArrow: Int64 = 123
    public static let rightArrow: Int64 = 124
    public static let downArrow: Int64 = 125
    public static let upArrow: Int64 = 126
}

public struct KeyboardInput: Sendable {
    public let kind: KeyboardEventKind
    public let keyCode: Int64
    public let modifiers: KeyboardModifiers
    public let isRepeat: Bool
    public let characters: String?

    public init(
        kind: KeyboardEventKind,
        keyCode: Int64,
        modifiers: KeyboardModifiers,
        isRepeat: Bool,
        characters: String? = nil
    ) {
        self.kind = kind
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.isRepeat = isRepeat
        self.characters = characters
    }
}

public enum SwitcherAction: Equatable, Sendable {
    case cycle(backwards: Bool)
    case move(GridMove)
    case openNewWindow
    case quitApplication
    case commit
    case cancel
}

public enum KeyboardCommand: Equatable, Sendable {
    case switcher(SwitcherAction)
    case moveFocusedWindow(WindowMoveDirection)
}

public struct KeyboardDecision: Equatable, Sendable {
    public let command: KeyboardCommand?
    public let isConsumed: Bool

    public init(command: KeyboardCommand?, isConsumed: Bool) {
        self.command = command
        self.isConsumed = isConsumed
    }
}

public struct KeyboardInputSession: Sendable {
    private struct PendingSwitcherGesture: Sendable {
        let token: UInt64
        let triggerKeyCode: Int64
        let action: SwitcherAction
        var isTriggerKeyDown: Bool
    }

    public private(set) var isCycling = false
    private var pendingSwitcherGesture: PendingSwitcherGesture?
    private var lastSwitcherGestureToken: UInt64 = 0

    public var hasPendingSwitcherGesture: Bool {
        pendingSwitcherGesture != nil
    }

    /// Identifies the pending gesture so a caller timing it out can tell one
    /// gesture being replaced by another from the same gesture still waiting.
    public var pendingSwitcherGestureToken: UInt64? {
        pendingSwitcherGesture?.token
    }

    public init() {}

    public mutating func interpret(
        _ input: KeyboardInput,
        capturesCommandTab: Bool
    ) -> KeyboardDecision {
        if let pendingSwitcherGesture {
            if let decision = continueSwitcherGesture(
                pendingSwitcherGesture,
                with: input
            ) {
                updateSession(for: decision)
                return decision
            }

            // The gesture waits for a key release that another key press says
            // is no longer coming. Drop it and read this event normally so a
            // stray Command-N cannot swallow the rest of the session.
            self.pendingSwitcherGesture = nil
        }

        if let action = switcherGestureAction(for: input) {
            lastSwitcherGestureToken += 1
            pendingSwitcherGesture = PendingSwitcherGesture(
                token: lastSwitcherGestureToken,
                triggerKeyCode: input.keyCode,
                action: action,
                isTriggerKeyDown: true
            )
            return KeyboardDecision(command: nil, isConsumed: true)
        }

        let decision = decision(
            for: input,
            capturesCommandTab: capturesCommandTab
        )

        updateSession(for: decision)
        return decision
    }

    private mutating func updateSession(for decision: KeyboardDecision) {
        switch decision.command {
        case .switcher(.cycle):
            isCycling = true
        case .switcher(.openNewWindow),
             .switcher(.quitApplication),
             .switcher(.commit),
             .switcher(.cancel):
            reset()
        case .switcher(.move), .moveFocusedWindow, nil:
            break
        }
    }

    public mutating func interrupt() -> KeyboardCommand? {
        guard isCycling else {
            return nil
        }

        reset()
        return .switcher(.cancel)
    }

    public mutating func cancelPendingSwitcherGesture() -> KeyboardCommand? {
        guard pendingSwitcherGesture != nil else {
            return nil
        }

        reset()
        return .switcher(.cancel)
    }

    public mutating func reset() {
        isCycling = false
        pendingSwitcherGesture = nil
    }

    private func switcherGestureAction(
        for input: KeyboardInput
    ) -> SwitcherAction? {
        guard isCycling,
              input.kind == .keyDown,
              !input.isRepeat,
              input.modifiers == [.command] else {
            return nil
        }

        if input.keyCode == KeyboardKeyCode.ansiN
            || input.characters?.lowercased() == "n" {
            return .openNewWindow
        }

        if input.keyCode == KeyboardKeyCode.ansiQ
            || input.characters?.lowercased() == "q" {
            return .quitApplication
        }

        return nil
    }

    /// Advances the pending gesture, or returns nil when `input` belongs to
    /// the session rather than to the gesture.
    private mutating func continueSwitcherGesture(
        _ pendingGesture: PendingSwitcherGesture,
        with input: KeyboardInput
    ) -> KeyboardDecision? {
        if input.kind == .keyDown,
           input.keyCode != pendingGesture.triggerKeyCode {
            return nil
        }

        var gesture = pendingGesture

        if input.kind == .keyUp,
           input.keyCode == gesture.triggerKeyCode {
            gesture.isTriggerKeyDown = false
        }

        let isCommandDown = input.modifiers.contains(.command)
        let isComplete = !gesture.isTriggerKeyDown
            && !isCommandDown
        pendingSwitcherGesture = isComplete ? nil : gesture

        return KeyboardDecision(
            command: isComplete
                ? .switcher(gesture.action)
                : nil,
            isConsumed: input.kind != .flagsChanged
        )
    }

    private func decision(
        for input: KeyboardInput,
        capturesCommandTab: Bool
    ) -> KeyboardDecision {
        if input.kind == .flagsChanged {
            let command: KeyboardCommand? = isCycling
                && !input.modifiers.contains(.command)
                ? .switcher(.commit)
                : nil
            return KeyboardDecision(command: command, isConsumed: false)
        }

        let windowMoveModifiers: KeyboardModifiers = [
            .control,
            .option,
            .command,
        ]

        if !isCycling,
           input.kind == .keyDown,
           input.modifiers == windowMoveModifiers,
           let direction = windowMoveDirection(for: input.keyCode) {
            return KeyboardDecision(
                command: input.isRepeat
                    ? nil
                    : .moveFocusedWindow(direction),
                isConsumed: true
            )
        }

        let isCommandTab = capturesCommandTab
            && input.kind == .keyDown
            && input.keyCode == KeyboardKeyCode.tab
            && input.modifiers.contains(.command)
            && !input.modifiers.contains(.control)
            && !input.modifiers.contains(.option)

        if isCommandTab {
            return KeyboardDecision(
                command: .switcher(
                    .cycle(backwards: input.modifiers.contains(.shift))
                ),
                isConsumed: true
            )
        }

        guard isCycling else {
            return KeyboardDecision(command: nil, isConsumed: false)
        }

        guard input.kind == .keyDown else {
            return KeyboardDecision(command: nil, isConsumed: true)
        }

        if input.keyCode == KeyboardKeyCode.escape {
            return KeyboardDecision(command: .switcher(.cancel), isConsumed: true)
        }

        if input.keyCode == KeyboardKeyCode.returnKey
            || input.keyCode == KeyboardKeyCode.keypadEnter {
            return KeyboardDecision(command: .switcher(.commit), isConsumed: true)
        }

        guard input.modifiers.contains(.command) else {
            return KeyboardDecision(command: .switcher(.commit), isConsumed: true)
        }

        let action: SwitcherAction? = switch input.keyCode {
        case KeyboardKeyCode.leftArrow:
            .move(.left)
        case KeyboardKeyCode.rightArrow:
            .move(.right)
        case KeyboardKeyCode.upArrow:
            .move(.up)
        case KeyboardKeyCode.downArrow:
            .move(.down)
        default:
            nil
        }

        return KeyboardDecision(
            command: action.map(KeyboardCommand.switcher),
            isConsumed: true
        )
    }

    private func windowMoveDirection(
        for keyCode: Int64
    ) -> WindowMoveDirection? {
        switch keyCode {
        case KeyboardKeyCode.leftArrow:
            .left
        case KeyboardKeyCode.rightArrow:
            .right
        case KeyboardKeyCode.upArrow:
            .up
        case KeyboardKeyCode.downArrow:
            .down
        default:
            nil
        }
    }
}
