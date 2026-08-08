import XCTest
@testable import RufCore

final class KeyboardInputSessionTests: XCTestCase {
    private let newWindowKeyCode: Int64 = 99
    private let quitKeyCode: Int64 = 98

    func testCommandTabStartsForwardOrBackwardCycling() {
        var forwardSession = KeyboardInputSession()
        var backwardSession = KeyboardInputSession()

        let forward = forwardSession.interpret(
            commandTabInput(),
            capturesCommandTab: true
        )
        let backward = backwardSession.interpret(
            commandTabInput(backwards: true),
            capturesCommandTab: true
        )

        XCTAssertEqual(
            forward,
            switcherDecision(.cycle(backwards: false))
        )
        XCTAssertEqual(
            backward,
            switcherDecision(.cycle(backwards: true))
        )
        XCTAssertTrue(forwardSession.isCycling)
        XCTAssertTrue(backwardSession.isCycling)
    }

    func testReleasingCommandCommitsWithoutSwallowingTheModifierEvent() {
        var session = cyclingSession()

        let decision = session.interpret(
            commandReleaseInput(),
            capturesCommandTab: true
        )

        XCTAssertEqual(
            decision,
            switcherDecision(.commit, isConsumed: false)
        )
        XCTAssertFalse(session.isCycling)
    }

    func testArrowAndEscapeKeysControlAnOpenSwitcher() {
        let cases: [(Int64, SwitcherAction)] = [
            (KeyboardKeyCode.leftArrow, .move(.left)),
            (KeyboardKeyCode.rightArrow, .move(.right)),
            (KeyboardKeyCode.upArrow, .move(.up)),
            (KeyboardKeyCode.downArrow, .move(.down)),
            (KeyboardKeyCode.escape, .cancel),
        ]

        for (keyCode, action) in cases {
            var session = cyclingSession()
            let decision = session.interpret(
                KeyboardInput(
                    kind: .keyDown,
                    keyCode: keyCode,
                    modifiers: [.command],
                    isRepeat: false
                ),
                capturesCommandTab: true
            )

            XCTAssertEqual(decision, switcherDecision(action))
        }
    }

    func testReturnCommitsTheSelectedTarget() {
        for keyCode in [KeyboardKeyCode.returnKey, KeyboardKeyCode.keypadEnter] {
            var session = cyclingSession()

            let decision = session.interpret(
                KeyboardInput(
                    kind: .keyDown,
                    keyCode: keyCode,
                    modifiers: [.command],
                    isRepeat: false
                ),
                capturesCommandTab: true
            )

            XCTAssertEqual(
                decision,
                switcherDecision(.commit)
            )
            XCTAssertFalse(session.isCycling)
        }
    }

    func testNewWindowGestureCompletesAfterNThenCommandAreReleased() {
        var session = cyclingSession()

        let keyDown = session.interpret(
            commandNInput(),
            capturesCommandTab: true
        )

        XCTAssertEqual(
            keyDown,
            KeyboardDecision(command: nil, isConsumed: true)
        )
        XCTAssertTrue(session.isCycling)

        let repeated = session.interpret(
            commandNInput(isRepeat: true),
            capturesCommandTab: true
        )
        XCTAssertEqual(
            repeated,
            KeyboardDecision(command: nil, isConsumed: true)
        )

        let nRelease = session.interpret(
            KeyboardInput(
                kind: .keyUp,
                keyCode: newWindowKeyCode,
                modifiers: [.command],
                isRepeat: false
            ),
            capturesCommandTab: true
        )
        XCTAssertEqual(
            nRelease,
            KeyboardDecision(command: nil, isConsumed: true)
        )
        XCTAssertTrue(session.isCycling)

        let commandRelease = session.interpret(
            commandReleaseInput(),
            capturesCommandTab: true
        )
        XCTAssertEqual(
            commandRelease,
            switcherDecision(.openNewWindow, isConsumed: false)
        )
        XCTAssertFalse(session.isCycling)
    }

    func testNewWindowGestureCompletesAfterCommandThenNAreReleased() {
        var session = cyclingSession()
        _ = session.interpret(commandNInput(), capturesCommandTab: true)

        let commandRelease = session.interpret(
            commandReleaseInput(),
            capturesCommandTab: true
        )
        XCTAssertEqual(
            commandRelease,
            KeyboardDecision(command: nil, isConsumed: false)
        )
        XCTAssertTrue(session.isCycling)

        let repeated = session.interpret(
            KeyboardInput(
                kind: .keyDown,
                keyCode: newWindowKeyCode,
                modifiers: [],
                isRepeat: true,
                characters: "n"
            ),
            capturesCommandTab: true
        )
        XCTAssertEqual(
            repeated,
            KeyboardDecision(command: nil, isConsumed: true)
        )

        let nRelease = session.interpret(
            KeyboardInput(
                kind: .keyUp,
                keyCode: newWindowKeyCode,
                modifiers: [],
                isRepeat: false
            ),
            capturesCommandTab: true
        )
        XCTAssertEqual(nRelease, switcherDecision(.openNewWindow))
        XCTAssertFalse(session.isCycling)

        let nextCommandN = session.interpret(
            commandNInput(),
            capturesCommandTab: true
        )
        XCTAssertEqual(
            nextCommandN,
            KeyboardDecision(command: nil, isConsumed: false)
        )
    }

    func testNewWindowGestureRecognizesThePhysicalNKeyOnNonLatinLayouts() {
        var session = cyclingSession()

        let keyDown = session.interpret(
            KeyboardInput(
                kind: .keyDown,
                keyCode: KeyboardKeyCode.ansiN,
                modifiers: [.command],
                isRepeat: false,
                characters: "т"
            ),
            capturesCommandTab: true
        )
        XCTAssertEqual(
            keyDown,
            KeyboardDecision(command: nil, isConsumed: true)
        )

        _ = session.interpret(
            KeyboardInput(
                kind: .keyUp,
                keyCode: KeyboardKeyCode.ansiN,
                modifiers: [.command],
                isRepeat: false
            ),
            capturesCommandTab: true
        )
        let commandRelease = session.interpret(
            commandReleaseInput(),
            capturesCommandTab: true
        )

        XCTAssertEqual(
            commandRelease,
            switcherDecision(.openNewWindow, isConsumed: false)
        )
    }

    func testPendingNewWindowGestureSurvivesModifierChangesWhileCommandIsHeld() {
        var session = cyclingSession()
        _ = session.interpret(commandNInput(), capturesCommandTab: true)

        let capsLockChange = session.interpret(
            KeyboardInput(
                kind: .flagsChanged,
                keyCode: 57,
                modifiers: [.command],
                isRepeat: false
            ),
            capturesCommandTab: true
        )
        XCTAssertEqual(
            capsLockChange,
            KeyboardDecision(command: nil, isConsumed: false)
        )

        _ = session.interpret(
            KeyboardInput(
                kind: .keyUp,
                keyCode: newWindowKeyCode,
                modifiers: [.command],
                isRepeat: false
            ),
            capturesCommandTab: true
        )
        let commandRelease = session.interpret(
            commandReleaseInput(),
            capturesCommandTab: true
        )

        XCTAssertEqual(
            commandRelease,
            switcherDecision(.openNewWindow, isConsumed: false)
        )
    }

    func testNewWindowActionRequiresCommandNWithoutExtraModifiers() {
        var session = cyclingSession()

        let decision = session.interpret(
            KeyboardInput(
                kind: .keyDown,
                keyCode: newWindowKeyCode,
                modifiers: [.command, .shift],
                isRepeat: false,
                characters: "N"
            ),
            capturesCommandTab: true
        )

        XCTAssertEqual(
            decision,
            KeyboardDecision(command: nil, isConsumed: true)
        )
        XCTAssertTrue(session.isCycling)
    }

    func testQuitApplicationGestureCompletesAfterQAndCommandAreReleased() {
        var session = cyclingSession()

        let keyDown = session.interpret(
            KeyboardInput(
                kind: .keyDown,
                keyCode: KeyboardKeyCode.ansiQ,
                modifiers: [.command],
                isRepeat: false,
                characters: "й"
            ),
            capturesCommandTab: true
        )
        XCTAssertEqual(
            keyDown,
            KeyboardDecision(command: nil, isConsumed: true)
        )

        let repeated = session.interpret(
            KeyboardInput(
                kind: .keyDown,
                keyCode: KeyboardKeyCode.ansiQ,
                modifiers: [.command],
                isRepeat: true,
                characters: "й"
            ),
            capturesCommandTab: true
        )
        XCTAssertEqual(
            repeated,
            KeyboardDecision(command: nil, isConsumed: true)
        )

        let qRelease = session.interpret(
            KeyboardInput(
                kind: .keyUp,
                keyCode: KeyboardKeyCode.ansiQ,
                modifiers: [.command],
                isRepeat: false
            ),
            capturesCommandTab: true
        )
        XCTAssertEqual(
            qRelease,
            KeyboardDecision(command: nil, isConsumed: true)
        )

        let commandRelease = session.interpret(
            commandReleaseInput(),
            capturesCommandTab: true
        )
        XCTAssertEqual(
            commandRelease,
            switcherDecision(.quitApplication, isConsumed: false)
        )
        XCTAssertFalse(session.isCycling)
    }

    func testPendingNewWindowGestureCancelsWhenTheEventTapIsInterrupted() {
        var session = cyclingSession()
        _ = session.interpret(commandNInput(), capturesCommandTab: true)

        XCTAssertEqual(session.interrupt(), .switcher(.cancel))
        XCTAssertEqual(
            session.interpret(commandTabInput(), capturesCommandTab: true),
            switcherDecision(.cycle(backwards: false))
        )
    }

    func testOpenSwitcherConsumesUnknownCommandsAndKeyUpEvents() {
        var session = cyclingSession()

        let commandW = session.interpret(
            KeyboardInput(
                kind: .keyDown,
                keyCode: 13,
                modifiers: [.command],
                isRepeat: false
            ),
            capturesCommandTab: true
        )
        let tabKeyUp = session.interpret(
            KeyboardInput(
                kind: .keyUp,
                keyCode: KeyboardKeyCode.tab,
                modifiers: [.command],
                isRepeat: false
            ),
            capturesCommandTab: true
        )

        XCTAssertEqual(commandW, KeyboardDecision(command: nil, isConsumed: true))
        XCTAssertEqual(tabKeyUp, KeyboardDecision(command: nil, isConsumed: true))
    }

    func testUnrelatedInputPassesThroughWhileClosed() {
        var session = KeyboardInputSession()

        let commandQ = session.interpret(
            KeyboardInput(
                kind: .keyDown,
                keyCode: KeyboardKeyCode.ansiQ,
                modifiers: [.command],
                isRepeat: false
            ),
            capturesCommandTab: true
        )
        let optionTab = session.interpret(
            KeyboardInput(
                kind: .keyDown,
                keyCode: KeyboardKeyCode.tab,
                modifiers: [.command, .option],
                isRepeat: false
            ),
            capturesCommandTab: true
        )

        XCTAssertEqual(commandQ, KeyboardDecision(command: nil, isConsumed: false))
        XCTAssertEqual(optionTab, KeyboardDecision(command: nil, isConsumed: false))
    }

    func testWindowMovementShortcutMapsEveryArrowWithoutOpeningSwitcher() {
        let cases: [(Int64, WindowMoveDirection)] = [
            (KeyboardKeyCode.leftArrow, .left),
            (KeyboardKeyCode.rightArrow, .right),
            (KeyboardKeyCode.upArrow, .up),
            (KeyboardKeyCode.downArrow, .down),
        ]

        for (keyCode, direction) in cases {
            var session = KeyboardInputSession()
            let decision = session.interpret(
                KeyboardInput(
                    kind: .keyDown,
                    keyCode: keyCode,
                    modifiers: [.control, .option, .command],
                    isRepeat: false
                ),
                capturesCommandTab: true
            )

            XCTAssertEqual(
                decision,
                KeyboardDecision(
                    command: .moveFocusedWindow(direction),
                    isConsumed: true
                )
            )
            XCTAssertFalse(session.isCycling)
        }
    }

    func testWindowMovementShortcutRequiresTheExactModifiersAndKeyDown() {
        let inputs = [
            KeyboardInput(
                kind: .keyDown,
                keyCode: KeyboardKeyCode.rightArrow,
                modifiers: [.control, .command],
                isRepeat: false
            ),
            KeyboardInput(
                kind: .keyDown,
                keyCode: KeyboardKeyCode.rightArrow,
                modifiers: [.control, .option, .command, .shift],
                isRepeat: false
            ),
            KeyboardInput(
                kind: .keyUp,
                keyCode: KeyboardKeyCode.rightArrow,
                modifiers: [.control, .option, .command],
                isRepeat: false
            ),
        ]

        for input in inputs {
            var session = KeyboardInputSession()
            XCTAssertEqual(
                session.interpret(input, capturesCommandTab: true),
                KeyboardDecision(command: nil, isConsumed: false)
            )
        }
    }

    func testWindowMovementShortcutConsumesKeyRepeatWithoutMovingAgain() {
        var session = KeyboardInputSession()

        let decision = session.interpret(
            KeyboardInput(
                kind: .keyDown,
                keyCode: KeyboardKeyCode.rightArrow,
                modifiers: [.control, .option, .command],
                isRepeat: true
            ),
            capturesCommandTab: true
        )

        XCTAssertEqual(
            decision,
            KeyboardDecision(command: nil, isConsumed: true)
        )
    }

    func testDisabledWindowMovementShortcutPassesThrough() {
        for isRepeat in [false, true] {
            var session = KeyboardInputSession()

            let decision = session.interpret(
                KeyboardInput(
                    kind: .keyDown,
                    keyCode: KeyboardKeyCode.rightArrow,
                    modifiers: [.control, .option, .command],
                    isRepeat: isRepeat
                ),
                capturesCommandTab: true,
                capturesWindowMovement: false
            )

            XCTAssertEqual(
                decision,
                KeyboardDecision(command: nil, isConsumed: false)
            )
        }
    }

    func testDisabledWindowMovementChordStillNavigatesAnOpenSwitcher() {
        var session = cyclingSession()

        let decision = session.interpret(
            KeyboardInput(
                kind: .keyDown,
                keyCode: KeyboardKeyCode.rightArrow,
                modifiers: [.control, .option, .command],
                isRepeat: false
            ),
            capturesCommandTab: true,
            capturesWindowMovement: false
        )

        XCTAssertEqual(decision, switcherDecision(.move(.right)))
        XCTAssertTrue(session.isCycling)
    }

    func testSystemCommandTabPassesThroughWhileWindowMovementStillWorks() {
        var session = KeyboardInputSession()

        XCTAssertEqual(
            session.interpret(commandTabInput(), capturesCommandTab: false),
            KeyboardDecision(command: nil, isConsumed: false)
        )
        XCTAssertEqual(
            session.interpret(
                KeyboardInput(
                    kind: .keyDown,
                    keyCode: KeyboardKeyCode.downArrow,
                    modifiers: [.control, .option, .command],
                    isRepeat: false
                ),
                capturesCommandTab: false
            ),
            KeyboardDecision(
                command: .moveFocusedWindow(.down),
                isConsumed: true
            )
        )
    }

    func testSessionRecoversWhenCommandReleaseWasMissed() {
        var session = cyclingSession()

        let recovery = session.interpret(
            KeyboardInput(
                kind: .keyDown,
                keyCode: 0,
                modifiers: [],
                isRepeat: false
            ),
            capturesCommandTab: true
        )

        XCTAssertEqual(recovery, switcherDecision(.commit))
        XCTAssertFalse(session.isCycling)
    }

    func testPendingSwitcherGestureCancelsWithEscape() {
        var session = cyclingSession()
        _ = session.interpret(commandNInput(), capturesCommandTab: true)

        let decision = session.interpret(
            KeyboardInput(
                kind: .keyDown,
                keyCode: KeyboardKeyCode.escape,
                modifiers: [.command],
                isRepeat: false
            ),
            capturesCommandTab: true
        )

        XCTAssertEqual(decision, switcherDecision(.cancel))
        XCTAssertFalse(session.isCycling)
        XCTAssertNil(session.pendingSwitcherGestureToken)
    }

    func testPendingSwitcherGestureCanBeCancelledByItsDeadline() {
        var session = cyclingSession()
        _ = session.interpret(commandNInput(), capturesCommandTab: true)

        XCTAssertNotNil(session.pendingSwitcherGestureToken)
        XCTAssertEqual(
            session.cancelPendingSwitcherGesture(),
            .switcher(.cancel)
        )
        XCTAssertFalse(session.isCycling)
        XCTAssertNil(session.pendingSwitcherGestureToken)
        XCTAssertNil(session.cancelPendingSwitcherGesture())
    }

    func testPendingSwitcherGestureYieldsToSwitcherNavigation() {
        var session = cyclingSession()
        _ = session.interpret(commandNInput(), capturesCommandTab: true)

        let decision = session.interpret(
            KeyboardInput(
                kind: .keyDown,
                keyCode: KeyboardKeyCode.rightArrow,
                modifiers: [.command],
                isRepeat: false
            ),
            capturesCommandTab: true
        )

        XCTAssertEqual(decision, switcherDecision(.move(.right)))
        XCTAssertTrue(session.isCycling)
        XCTAssertNil(session.pendingSwitcherGestureToken)
    }

    func testPendingSwitcherGestureYieldsToAnotherCycle() {
        var session = cyclingSession()
        _ = session.interpret(commandNInput(), capturesCommandTab: true)

        let decision = session.interpret(
            commandTabInput(),
            capturesCommandTab: true
        )

        XCTAssertEqual(decision, switcherDecision(.cycle(backwards: false)))
        XCTAssertTrue(session.isCycling)
        XCTAssertNil(session.pendingSwitcherGestureToken)
    }

    func testPendingSwitcherGestureIsReplacedByADifferentGesture() {
        var session = cyclingSession()
        _ = session.interpret(commandNInput(), capturesCommandTab: true)

        XCTAssertEqual(
            session.interpret(commandQInput(), capturesCommandTab: true),
            KeyboardDecision(command: nil, isConsumed: true)
        )
        XCTAssertNotNil(session.pendingSwitcherGestureToken)

        _ = session.interpret(
            KeyboardInput(
                kind: .keyUp,
                keyCode: quitKeyCode,
                modifiers: [.command],
                isRepeat: false
            ),
            capturesCommandTab: true
        )

        XCTAssertEqual(
            session.interpret(
                commandReleaseInput(),
                capturesCommandTab: true
            ),
            switcherDecision(.quitApplication, isConsumed: false)
        )
        XCTAssertFalse(session.isCycling)
    }

    func testPendingSwitcherGestureSurvivesItsOwnKeyRepeat() {
        var session = cyclingSession()
        _ = session.interpret(commandNInput(), capturesCommandTab: true)

        let decision = session.interpret(
            commandNInput(isRepeat: true),
            capturesCommandTab: true
        )

        XCTAssertEqual(
            decision,
            KeyboardDecision(command: nil, isConsumed: true)
        )
        XCTAssertNotNil(session.pendingSwitcherGestureToken)

        _ = session.interpret(
            KeyboardInput(
                kind: .keyUp,
                keyCode: newWindowKeyCode,
                modifiers: [.command],
                isRepeat: false
            ),
            capturesCommandTab: true
        )

        XCTAssertEqual(
            session.interpret(
                commandReleaseInput(),
                capturesCommandTab: true
            ),
            switcherDecision(.openNewWindow, isConsumed: false)
        )
    }

    func testSessionCancelsWhenTheEventTapIsInterrupted() {
        var session = cyclingSession()

        XCTAssertEqual(session.interrupt(), .switcher(.cancel))
        XCTAssertFalse(session.isCycling)
        XCTAssertNil(session.interrupt())
    }

    private func cyclingSession() -> KeyboardInputSession {
        var session = KeyboardInputSession()
        _ = session.interpret(
            commandTabInput(),
            capturesCommandTab: true
        )
        return session
    }

    private func commandTabInput(backwards: Bool = false) -> KeyboardInput {
        KeyboardInput(
            kind: .keyDown,
            keyCode: KeyboardKeyCode.tab,
            modifiers: backwards ? [.command, .shift] : [.command],
            isRepeat: false
        )
    }

    private func commandNInput(isRepeat: Bool = false) -> KeyboardInput {
        KeyboardInput(
            kind: .keyDown,
            keyCode: newWindowKeyCode,
            modifiers: [.command],
            isRepeat: isRepeat,
            characters: "n"
        )
    }

    private func commandQInput(isRepeat: Bool = false) -> KeyboardInput {
        KeyboardInput(
            kind: .keyDown,
            keyCode: quitKeyCode,
            modifiers: [.command],
            isRepeat: isRepeat,
            characters: "q"
        )
    }

    private func commandReleaseInput() -> KeyboardInput {
        KeyboardInput(
            kind: .flagsChanged,
            keyCode: 55,
            modifiers: [],
            isRepeat: false
        )
    }

    private func switcherDecision(
        _ action: SwitcherAction,
        isConsumed: Bool = true
    ) -> KeyboardDecision {
        KeyboardDecision(
            command: .switcher(action),
            isConsumed: isConsumed
        )
    }
}
