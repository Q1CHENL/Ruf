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
    public static let ansiI: Int64 = 34
    public static let ansiN: Int64 = 45
    public static let ansiQ: Int64 = 12
    public static let tab: Int64 = 48
    public static let returnKey: Int64 = 36
    public static let keypadEnter: Int64 = 76
    public static let escape: Int64 = 53
    public static let pageUp: Int64 = 116
    public static let pageDown: Int64 = 121
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

extension KeyboardInput {
    /// Whether this key press types `letter`. A layout that types ASCII
    /// characters names the key by what it types, wherever the key sits, so
    /// AZERTY's A key in the ANSI Q position is never Q. Only a layout without
    /// ASCII characters on the key, such as Cyrillic, falls back to the key in
    /// the letter's ANSI position.
    func types(_ letter: String, ansiKeyCode: Int64) -> Bool {
        guard let characters,
              !characters.isEmpty,
              characters.allSatisfy(\.isASCII) else {
            return keyCode == ansiKeyCode
        }

        return characters.lowercased() == letter
    }
}

public enum SwitcherAction: Equatable, Sendable {
    case cycle(backwards: Bool)
    case move(GridMove)
    case toggleApplicationResourceUsage
    case openNewWindow
    case quitApplication
    case commit
    case cancel
}

public struct SwitcherCommand: Equatable, Sendable {
    public let gestureID: UInt64
    public let action: SwitcherAction

    public init(gestureID: UInt64, action: SwitcherAction) {
        self.gestureID = gestureID
        self.action = action
    }
}

public enum KeyboardCommand: Equatable, Sendable {
    case switcher(SwitcherCommand)
    case moveFocusedWindow(WindowMoveDirection)
}

public struct SwitcherShortcuts: OptionSet, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let jumpToFirstOrLast = Self(rawValue: 1 << 0)
    public static let openNewWindow = Self(rawValue: 1 << 1)
    public static let quitApplication = Self(rawValue: 1 << 2)
    public static let all: Self = [
        .jumpToFirstOrLast,
        .openNewWindow,
        .quitApplication,
    ]
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

    private var activeSwitcherGestureID: UInt64?
    private var pendingSwitcherGesture: PendingSwitcherGesture?
    private var lastPendingSwitcherGestureToken: UInt64 = 0
    private var lastSwitcherGestureID: UInt64 = 0
    /// Keys whose press the switcher consumed and that are still down. A
    /// gesture can end while one is held, so its repeats and release stay
    /// consumed instead of reaching the application the gesture activated.
    private var consumedKeyCodes: Set<Int64> = []

    public var isCycling: Bool {
        activeSwitcherGestureID != nil
    }

    /// Identifies a pending terminal gesture so its deadline cannot expire a
    /// replacement gesture that started while the deadline task was waiting.
    public var pendingSwitcherGestureToken: UInt64? {
        pendingSwitcherGesture?.token
    }

    /// The key whose release the pending terminal gesture waits for.
    public var pendingSwitcherGestureKeyCode: Int64? {
        pendingSwitcherGesture?.triggerKeyCode
    }

    public init() {}

    public mutating func interpret(
        _ input: KeyboardInput,
        capturesCommandTab: Bool,
        capturesWindowMovement: Bool = true,
        enabledSwitcherShortcuts: SwitcherShortcuts = .all
    ) -> KeyboardDecision {
        if let decision = continueConsumedKeyPress(with: input) {
            return decision
        }

        let wasCycling = isCycling
        let decision = interpretSwitcherInput(
            input,
            capturesCommandTab: capturesCommandTab,
            capturesWindowMovement: capturesWindowMovement,
            enabledSwitcherShortcuts: enabledSwitcherShortcuts
        )

        if input.kind == .keyDown,
           decision.isConsumed,
           wasCycling || isCycling {
            consumedKeyCodes.insert(input.keyCode)
        }

        return decision
    }

    /// Keeps consuming a held key's repeats and release after the gesture
    /// that consumed its press has ended. Returns nil when the session should
    /// read `input` itself.
    private mutating func continueConsumedKeyPress(
        with input: KeyboardInput
    ) -> KeyboardDecision? {
        guard input.kind != .flagsChanged,
              consumedKeyCodes.contains(input.keyCode) else {
            return nil
        }

        switch input.kind {
        case .keyDown where !input.isRepeat:
            // A new press means the release went unseen, so this press
            // belongs to whatever comes next.
            consumedKeyCodes.remove(input.keyCode)
            return nil
        case .keyUp:
            consumedKeyCodes.remove(input.keyCode)
        case .keyDown, .flagsChanged:
            break
        }

        return isCycling
            ? nil
            : KeyboardDecision(command: nil, isConsumed: true)
    }

    private mutating func interpretSwitcherInput(
        _ input: KeyboardInput,
        capturesCommandTab: Bool,
        capturesWindowMovement: Bool,
        enabledSwitcherShortcuts: SwitcherShortcuts
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

        if let action = switcherGestureAction(
            for: input,
            enabledShortcuts: enabledSwitcherShortcuts
        ) {
            lastPendingSwitcherGestureToken += 1
            pendingSwitcherGesture = PendingSwitcherGesture(
                token: lastPendingSwitcherGestureToken,
                triggerKeyCode: input.keyCode,
                action: action,
                isTriggerKeyDown: true
            )
            return KeyboardDecision(command: nil, isConsumed: true)
        }

        let decision = decision(
            for: input,
            capturesCommandTab: capturesCommandTab,
            capturesWindowMovement: capturesWindowMovement,
            enabledSwitcherShortcuts: enabledSwitcherShortcuts
        )

        updateSession(for: decision)
        return decision
    }

    private mutating func updateSession(for decision: KeyboardDecision) {
        guard case let .switcher(command) = decision.command else {
            return
        }

        switch command.action {
        case .openNewWindow, .quitApplication, .commit, .cancel:
            reset()
        case .cycle, .move, .toggleApplicationResourceUsage:
            break
        }
    }

    public mutating func interrupt() -> KeyboardCommand? {
        guard let command = switcherCommand(.cancel) else {
            return nil
        }

        reset()
        return command
    }

    public mutating func cancelPendingSwitcherGesture(
        expectedToken: UInt64
    ) -> KeyboardCommand? {
        guard pendingSwitcherGesture?.token == expectedToken,
              let command = switcherCommand(.cancel) else {
            return nil
        }

        reset()
        return command
    }

    public mutating func resetSwitcherGesture(ifMatching gestureID: UInt64) {
        guard activeSwitcherGestureID == gestureID else {
            return
        }

        reset()
    }

    public mutating func reset() {
        activeSwitcherGestureID = nil
        pendingSwitcherGesture = nil
    }

    private func switcherGestureAction(
        for input: KeyboardInput,
        enabledShortcuts: SwitcherShortcuts
    ) -> SwitcherAction? {
        guard isCycling,
              input.kind == .keyDown,
              !input.isRepeat,
              input.modifiers == [.command] else {
            return nil
        }

        if enabledShortcuts.contains(.openNewWindow),
           input.types("n", ansiKeyCode: KeyboardKeyCode.ansiN) {
            return .openNewWindow
        }

        if enabledShortcuts.contains(.quitApplication),
           input.types("q", ansiKeyCode: KeyboardKeyCode.ansiQ) {
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

        switch input.kind {
        case .keyDown:
            // Pressing the trigger key again, even after releasing it,
            // holds the gesture until this press is released too.
            gesture.isTriggerKeyDown = true
        case .keyUp where input.keyCode == gesture.triggerKeyCode:
            gesture.isTriggerKeyDown = false
        case .keyUp, .flagsChanged:
            break
        }

        let isCommandDown = input.modifiers.contains(.command)
        let isComplete = !gesture.isTriggerKeyDown
            && !isCommandDown
        pendingSwitcherGesture = isComplete ? nil : gesture

        return KeyboardDecision(
            command: isComplete
                ? switcherCommand(gesture.action)
                : nil,
            isConsumed: input.kind != .flagsChanged
        )
    }

    private mutating func decision(
        for input: KeyboardInput,
        capturesCommandTab: Bool,
        capturesWindowMovement: Bool,
        enabledSwitcherShortcuts: SwitcherShortcuts
    ) -> KeyboardDecision {
        if input.kind == .flagsChanged {
            let command: KeyboardCommand? = isCycling
                && !input.modifiers.contains(.command)
                ? switcherCommand(.commit)
                : nil
            return KeyboardDecision(command: command, isConsumed: false)
        }

        let windowMoveModifiers: KeyboardModifiers = [
            .control,
            .option,
            .command,
        ]

        if capturesWindowMovement,
           !isCycling,
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
                command: cycleCommand(
                    backwards: input.modifiers.contains(.shift)
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
            return KeyboardDecision(
                command: switcherCommand(.cancel),
                isConsumed: true
            )
        }

        if input.keyCode == KeyboardKeyCode.returnKey
            || input.keyCode == KeyboardKeyCode.keypadEnter {
            return KeyboardDecision(
                command: switcherCommand(.commit),
                isConsumed: true
            )
        }

        guard input.modifiers.contains(.command) else {
            return KeyboardDecision(
                command: switcherCommand(.commit),
                isConsumed: true
            )
        }

        if input.modifiers == [.command],
           !input.isRepeat,
           input.types("i", ansiKeyCode: KeyboardKeyCode.ansiI) {
            return KeyboardDecision(
                command: switcherCommand(
                    .toggleApplicationResourceUsage
                ),
                isConsumed: true
            )
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
        case KeyboardKeyCode.pageUp
            where enabledSwitcherShortcuts.contains(.jumpToFirstOrLast):
            .move(.first)
        case KeyboardKeyCode.pageDown
            where enabledSwitcherShortcuts.contains(.jumpToFirstOrLast):
            .move(.last)
        default:
            nil
        }

        return KeyboardDecision(
            command: action.flatMap(switcherCommand),
            isConsumed: true
        )
    }

    private mutating func cycleCommand(backwards: Bool) -> KeyboardCommand {
        let gestureID: UInt64
        if let activeSwitcherGestureID {
            gestureID = activeSwitcherGestureID
        } else {
            lastSwitcherGestureID += 1
            activeSwitcherGestureID = lastSwitcherGestureID
            gestureID = lastSwitcherGestureID
        }

        return .switcher(
            SwitcherCommand(
                gestureID: gestureID,
                action: .cycle(backwards: backwards)
            )
        )
    }

    private func switcherCommand(
        _ action: SwitcherAction
    ) -> KeyboardCommand? {
        activeSwitcherGestureID.map {
            .switcher(SwitcherCommand(gestureID: $0, action: action))
        }
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
