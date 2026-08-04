import XCTest
@testable import RufCore

final class KeyboardInputSessionTests: XCTestCase {
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
            KeyboardInput(
                kind: .flagsChanged,
                keyCode: 55,
                modifiers: [],
                isRepeat: false
            ),
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

    func testOpenSwitcherConsumesUnknownCommandsAndKeyUpEvents() {
        var session = cyclingSession()

        let commandQ = session.interpret(
            KeyboardInput(
                kind: .keyDown,
                keyCode: 12,
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

        XCTAssertEqual(commandQ, KeyboardDecision(command: nil, isConsumed: true))
        XCTAssertEqual(tabKeyUp, KeyboardDecision(command: nil, isConsumed: true))
    }

    func testUnrelatedInputPassesThroughWhileClosed() {
        var session = KeyboardInputSession()

        let commandQ = session.interpret(
            KeyboardInput(
                kind: .keyDown,
                keyCode: 12,
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

    func testWindowMovementChordStillNavigatesAnOpenSwitcher() {
        var session = cyclingSession()

        let decision = session.interpret(
            KeyboardInput(
                kind: .keyDown,
                keyCode: KeyboardKeyCode.rightArrow,
                modifiers: [.control, .option, .command],
                isRepeat: false
            ),
            capturesCommandTab: true
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
