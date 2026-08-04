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

    public init(
        kind: KeyboardEventKind,
        keyCode: Int64,
        modifiers: KeyboardModifiers,
        isRepeat: Bool
    ) {
        self.kind = kind
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.isRepeat = isRepeat
    }
}

public enum SwitcherAction: Equatable, Sendable {
    case cycle(backwards: Bool)
    case move(GridMove)
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
    public private(set) var isCycling = false

    public init() {}

    public mutating func interpret(
        _ input: KeyboardInput,
        capturesCommandTab: Bool
    ) -> KeyboardDecision {
        let decision = decision(
            for: input,
            capturesCommandTab: capturesCommandTab
        )

        switch decision.command {
        case .switcher(.cycle):
            isCycling = true
        case .switcher(.commit), .switcher(.cancel):
            reset()
        case .switcher(.move), .moveFocusedWindow, nil:
            break
        }

        return decision
    }

    public mutating func interrupt() -> KeyboardCommand? {
        guard isCycling else {
            return nil
        }

        reset()
        return .switcher(.cancel)
    }

    public mutating func reset() {
        isCycling = false
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
