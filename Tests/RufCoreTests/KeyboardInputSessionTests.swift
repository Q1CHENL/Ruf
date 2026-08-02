import XCTest
@testable import RufCore

final class KeyboardInputSessionTests: XCTestCase {
    func testCommandTabStartsForwardOrBackwardCycling() {
        var forwardSession = KeyboardInputSession()
        var backwardSession = KeyboardInputSession()

        let forward = forwardSession.interpret(commandTabInput())
        let backward = backwardSession.interpret(commandTabInput(backwards: true))

        XCTAssertEqual(
            forward,
            KeyboardDecision(action: .cycle(backwards: false), isConsumed: true)
        )
        XCTAssertEqual(
            backward,
            KeyboardDecision(action: .cycle(backwards: true), isConsumed: true)
        )
        XCTAssertTrue(forwardSession.isCycling)
        XCTAssertTrue(backwardSession.isCycling)
    }

    func testReleasingCommandCommitsWithoutSwallowingTheModifierEvent() {
        var session = cyclingSession()

        let decision = session.interpret(
            KeyboardInput(kind: .flagsChanged, keyCode: 55, modifiers: [])
        )

        XCTAssertEqual(decision, KeyboardDecision(action: .commit, isConsumed: false))
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
                KeyboardInput(kind: .keyDown, keyCode: keyCode, modifiers: [.command])
            )

            XCTAssertEqual(decision, KeyboardDecision(action: action, isConsumed: true))
        }
    }

    func testReturnCommitsTheSelectedTarget() {
        for keyCode in [KeyboardKeyCode.returnKey, KeyboardKeyCode.keypadEnter] {
            var session = cyclingSession()

            let decision = session.interpret(
                KeyboardInput(
                    kind: .keyDown,
                    keyCode: keyCode,
                    modifiers: [.command]
                )
            )

            XCTAssertEqual(
                decision,
                KeyboardDecision(action: .commit, isConsumed: true)
            )
            XCTAssertFalse(session.isCycling)
        }
    }

    func testOpenSwitcherConsumesUnknownCommandsAndKeyUpEvents() {
        var session = cyclingSession()

        let commandQ = session.interpret(
            KeyboardInput(kind: .keyDown, keyCode: 12, modifiers: [.command])
        )
        let tabKeyUp = session.interpret(
            KeyboardInput(
                kind: .keyUp,
                keyCode: KeyboardKeyCode.tab,
                modifiers: [.command]
            )
        )

        XCTAssertEqual(commandQ, KeyboardDecision(action: nil, isConsumed: true))
        XCTAssertEqual(tabKeyUp, KeyboardDecision(action: nil, isConsumed: true))
    }

    func testUnrelatedInputPassesThroughWhileClosed() {
        var session = KeyboardInputSession()

        let commandQ = session.interpret(
            KeyboardInput(kind: .keyDown, keyCode: 12, modifiers: [.command])
        )
        let optionTab = session.interpret(
            KeyboardInput(
                kind: .keyDown,
                keyCode: KeyboardKeyCode.tab,
                modifiers: [.command, .option]
            )
        )

        XCTAssertEqual(commandQ, KeyboardDecision(action: nil, isConsumed: false))
        XCTAssertEqual(optionTab, KeyboardDecision(action: nil, isConsumed: false))
    }

    func testSessionRecoversWhenCommandReleaseWasMissed() {
        var session = cyclingSession()

        let recovery = session.interpret(
            KeyboardInput(kind: .keyDown, keyCode: 0, modifiers: [])
        )

        XCTAssertEqual(recovery, KeyboardDecision(action: .commit, isConsumed: true))
        XCTAssertFalse(session.isCycling)
    }

    func testSessionCancelsWhenTheEventTapIsInterrupted() {
        var session = cyclingSession()

        XCTAssertEqual(session.interrupt(), .cancel)
        XCTAssertFalse(session.isCycling)
        XCTAssertNil(session.interrupt())
    }

    private func cyclingSession() -> KeyboardInputSession {
        var session = KeyboardInputSession()
        _ = session.interpret(commandTabInput())
        return session
    }

    private func commandTabInput(backwards: Bool = false) -> KeyboardInput {
        KeyboardInput(
            kind: .keyDown,
            keyCode: KeyboardKeyCode.tab,
            modifiers: backwards ? [.command, .shift] : [.command]
        )
    }
}
