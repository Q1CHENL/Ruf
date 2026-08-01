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

    public init(
        kind: KeyboardEventKind,
        keyCode: Int64,
        modifiers: KeyboardModifiers
    ) {
        self.kind = kind
        self.keyCode = keyCode
        self.modifiers = modifiers
    }
}

public enum SwitcherAction: Equatable, Sendable {
    case cycle(backwards: Bool)
    case move(GridMove)
    case commit
    case cancel
}

public struct KeyboardDecision: Equatable, Sendable {
    public let action: SwitcherAction?
    public let isConsumed: Bool

    public init(action: SwitcherAction?, isConsumed: Bool) {
        self.action = action
        self.isConsumed = isConsumed
    }
}

public struct KeyboardInputSession: Sendable {
    public private(set) var isCycling = false

    public init() {}

    public mutating func interpret(_ input: KeyboardInput) -> KeyboardDecision {
        let decision = decision(for: input)

        switch decision.action {
        case .cycle:
            isCycling = true
        case .commit, .cancel:
            reset()
        case .move, nil:
            break
        }

        return decision
    }

    public mutating func interrupt() -> SwitcherAction? {
        guard isCycling else {
            return nil
        }

        reset()
        return .cancel
    }

    public mutating func reset() {
        isCycling = false
    }

    private func decision(for input: KeyboardInput) -> KeyboardDecision {
        if input.kind == .flagsChanged {
            let action: SwitcherAction? = isCycling
                && !input.modifiers.contains(.command)
                ? .commit
                : nil
            return KeyboardDecision(action: action, isConsumed: false)
        }

        let isCommandTab = input.kind == .keyDown
            && input.keyCode == KeyboardKeyCode.tab
            && input.modifiers.contains(.command)
            && !input.modifiers.contains(.control)
            && !input.modifiers.contains(.option)

        if isCommandTab {
            return KeyboardDecision(
                action: .cycle(backwards: input.modifiers.contains(.shift)),
                isConsumed: true
            )
        }

        guard isCycling else {
            return KeyboardDecision(action: nil, isConsumed: false)
        }

        guard input.kind == .keyDown else {
            return KeyboardDecision(action: nil, isConsumed: true)
        }

        if input.keyCode == KeyboardKeyCode.escape {
            return KeyboardDecision(action: .cancel, isConsumed: true)
        }

        guard input.modifiers.contains(.command) else {
            return KeyboardDecision(action: .commit, isConsumed: true)
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

        return KeyboardDecision(action: action, isConsumed: true)
    }
}
