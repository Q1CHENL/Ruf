import XCTest
@testable import RufCore

final class WindowMovementSessionTests: XCTestCase {
    private typealias Session = WindowMovementSession<String>
    private typealias Effect = WindowMovementEffect<String>

    private let left = display(x: 0)
    private let middle = display(x: 1_000)
    private let right = display(x: 2_000)
    private let window = CGRect(x: 100, y: 100, width: 500, height: 400)

    private var displays: [DisplayGeometry] {
        [left, middle, right]
    }

    func testContinuousMoveWritesEachFrameThenPlacesTheWindow() throws {
        var session = Session()

        XCTAssertEqual(move(&session, .right, from: window), [])
        let animation = try XCTUnwrap(session.animation)
        XCTAssertEqual(
            animation.destinationFrame,
            CGRect(x: 1_100, y: 100, width: 500, height: 400)
        )
        XCTAssertEqual(session.animatingDisplay, middle)
        XCTAssertNil(session.outlineFrame)

        // Ease in-out cubic: a quarter of the time covers 1/16 of the way.
        XCTAssertEqual(
            session.advance(to: 0.05),
            [frameWrite(animation, origin: CGPoint(x: 162.5, y: 100))]
        )
        XCTAssertEqual(
            session.advance(to: 0.1),
            [frameWrite(animation, origin: CGPoint(x: 600, y: 100))]
        )

        XCTAssertEqual(
            session.advance(to: 0.2),
            [
                .write(
                    WindowMovementWrite(
                        window: "editor",
                        animationIdentifier: animation.identifier,
                        purpose: .finalPlacement,
                        frame: animation.destinationFrame,
                        mutations: [.position(CGPoint(x: 1_100, y: 100))]
                    )
                ),
            ]
        )
        XCTAssertNil(session.animatingDisplay)
        XCTAssertEqual(session.advance(to: 0.21), [])

        XCTAssertEqual(
            session.writeDidFinish(
                .finalPlacement,
                animationIdentifier: animation.identifier,
                succeeded: true
            ),
            [.discardPendingWrites(animationIdentifier: animation.identifier)]
        )
        XCTAssertNil(session.animation)
    }

    func testGhostMoveAnimatesThePreviewAndWritesTheWindowOnce() throws {
        let source = display(x: 0)
        let small = DisplayGeometry(
            frame: CGRect(x: 1_000, y: 0, width: 500, height: 400),
            visibleFrame: CGRect(x: 1_000, y: 0, width: 500, height: 400)
        )
        let start = CGRect(x: 100, y: 100, width: 800, height: 600)
        let destination = CGRect(x: 1_000, y: 0, width: 500, height: 400)
        var session = Session()

        XCTAssertEqual(
            move(
                &session,
                .right,
                style: .outline,
                from: start,
                displays: [source, small]
            ),
            []
        )
        XCTAssertEqual(session.outlineFrame, start)

        XCTAssertEqual(session.advance(to: 0.05), [])
        assertFrame(
            session.outlineFrame,
            CGRect(x: 156.25, y: 93.75, width: 781.25, height: 587.5)
        )

        let animation = try XCTUnwrap(session.animation)
        XCTAssertEqual(
            session.advance(to: 0.2),
            [
                .write(
                    WindowMovementWrite(
                        window: "editor",
                        animationIdentifier: animation.identifier,
                        purpose: .finalPlacement,
                        frame: destination,
                        mutations: [
                            .position(destination.origin),
                            .size(destination.size),
                            .position(destination.origin),
                        ]
                    )
                ),
            ]
        )
        XCTAssertEqual(session.outlineFrame, destination)

        _ = session.writeDidFinish(
            .finalPlacement,
            animationIdentifier: animation.identifier,
            succeeded: true
        )
        XCTAssertNil(session.outlineFrame)
    }

    func testContinuousKeepsTheWindowSizeUntilTheFinalPlacement() throws {
        let small = DisplayGeometry(
            frame: CGRect(x: 1_000, y: 0, width: 500, height: 400),
            visibleFrame: CGRect(x: 1_000, y: 0, width: 500, height: 400)
        )
        let start = CGRect(x: 100, y: 100, width: 800, height: 600)
        var session = Session()

        _ = move(&session, .right, from: start, displays: [left, small])
        let animation = try XCTUnwrap(session.animation)

        guard case let .write(write) = try XCTUnwrap(
            session.advance(to: 0.1).first
        ) else {
            return XCTFail("Expected a frame write")
        }
        XCTAssertEqual(write.purpose, .frame)
        XCTAssertEqual(write.frame.size, start.size)
        XCTAssertEqual(write.mutations, [.position(write.frame.origin)])
        XCTAssertEqual(
            animation.finalPlacement,
            [
                .position(CGPoint(x: 1_000, y: 0)),
                .size(CGSize(width: 500, height: 400)),
                .position(CGPoint(x: 1_000, y: 0)),
            ]
        )
    }

    func testRefusesAResizeTheWindowDoesNotAllow() {
        let small = DisplayGeometry(
            frame: CGRect(x: 1_000, y: 0, width: 500, height: 400),
            visibleFrame: CGRect(x: 1_000, y: 0, width: 500, height: 400)
        )
        var session = Session()

        XCTAssertEqual(
            move(
                &session,
                .right,
                from: CGRect(x: 100, y: 100, width: 800, height: 600),
                displays: [left, small],
                canResize: false
            ),
            []
        )
        XCTAssertNil(session.animation)
    }

    func testAsksWhetherTheWindowCanResizeOnlyWhenTheSizeChanges() {
        var session = Session()
        var resizeQueries = 0

        _ = session.move(
            .right,
            style: .live,
            reducesMotion: false,
            window: "editor",
            frame: window,
            displays: displays,
            at: 0,
            canResize: {
                resizeQueries += 1
                return false
            }
        )

        XCTAssertEqual(resizeQueries, 0)
        XCTAssertNotNil(session.animation)
    }

    func testRetargetingWritesTheSizeAnEarlierPlacementMayStillChange() throws {
        let wide = display(x: 0)
        let small = DisplayGeometry(
            frame: CGRect(x: 1_000, y: 0, width: 500, height: 400),
            visibleFrame: CGRect(x: 1_000, y: 0, width: 500, height: 400)
        )
        let farWide = display(x: 1_500)
        let displays = [wide, small, farWide]
        let fullScreenFrame = wide.visibleFrame
        var session = Session()

        _ = move(
            &session,
            .right,
            reducesMotion: true,
            from: fullScreenFrame,
            displays: displays
        )
        let first = try XCTUnwrap(session.animation)
        XCTAssertEqual(first.destinationFrame, small.visibleFrame)

        // The first placement is still resizing the window, so the size read
        // back is the old one, which happens to match the next destination.
        let effects = move(
            &session,
            .right,
            reducesMotion: true,
            from: fullScreenFrame,
            displays: displays,
            at: 0.01
        )
        let second = try XCTUnwrap(session.animation)
        XCTAssertEqual(second.destinationFrame, farWide.visibleFrame)
        XCTAssertEqual(
            effects,
            [
                .discardPendingWrites(animationIdentifier: first.identifier),
                .write(
                    WindowMovementWrite(
                        window: "editor",
                        animationIdentifier: second.identifier,
                        purpose: .finalPlacement,
                        frame: farWide.visibleFrame,
                        mutations: [
                            .position(farWide.visibleFrame.origin),
                            .size(farWide.visibleFrame.size),
                            .position(farWide.visibleFrame.origin),
                        ]
                    )
                ),
            ]
        )
    }

    func testRetargetingAWindowThatCannotResizeKeepsItsSize() throws {
        var session = Session()
        _ = move(&session, .right, from: window)
        let first = try XCTUnwrap(session.animation)

        let effects = move(
            &session,
            .left,
            from: window,
            at: 0.01,
            canResize: false
        )

        XCTAssertEqual(
            effects,
            [
                .discardPendingWrites(animationIdentifier: first.identifier),
                finalPlacement(try XCTUnwrap(session.animation), window),
            ]
        )
    }

    func testRetargetingPlansFromTheDestinationInFlight() throws {
        var session = Session()
        _ = move(&session, .right, from: window)
        let first = try XCTUnwrap(session.animation)
        _ = session.advance(to: 0.1)

        let windowInFlight = CGRect(x: 600, y: 100, width: 500, height: 400)
        XCTAssertEqual(
            move(&session, .right, from: windowInFlight, at: 0.12),
            [.discardPendingWrites(animationIdentifier: first.identifier)]
        )

        let second = try XCTUnwrap(session.animation)
        XCTAssertEqual(second.destinationDisplay, right)
        XCTAssertEqual(
            second.destinationFrame,
            CGRect(x: 2_100, y: 100, width: 500, height: 400)
        )
        XCTAssertEqual(second.startFrame, windowInFlight)
        XCTAssertEqual(second.startTime, 0.12)
        XCTAssertEqual(session.animatingDisplay, right)
    }

    func testGhostRetargetingContinuesFromThePreview() throws {
        var session = Session()
        _ = move(&session, .right, style: .outline, from: window)
        _ = session.advance(to: 0.1)
        let preview = try XCTUnwrap(session.outlineFrame)

        // Ghost has not moved the real window yet.
        _ = move(&session, .right, style: .outline, from: window, at: 0.12)

        XCTAssertEqual(session.animation?.startFrame, preview)
        XCTAssertEqual(session.outlineFrame, preview)
    }

    func testContinuousAfterGhostStartsFromTheRealWindow() {
        var session = Session()
        _ = move(&session, .right, style: .outline, from: window)
        _ = session.advance(to: 0.1)

        _ = move(&session, .right, from: window, at: 0.12)

        XCTAssertEqual(session.animation?.startFrame, window)
        XCTAssertNil(session.outlineFrame)
    }

    func testReducedMotionPlacesAtOnceAndRapidMovesReachTheLastDisplay() throws {
        var session = Session()

        let firstEffects = move(
            &session,
            .right,
            style: .outline,
            reducesMotion: true,
            from: window
        )
        let first = try XCTUnwrap(session.animation)
        XCTAssertEqual(
            firstEffects,
            [finalPlacement(first, CGRect(x: 1_100, y: 100, width: 500, height: 400))]
        )
        XCTAssertNil(session.animatingDisplay)
        XCTAssertNil(session.outlineFrame)

        // The window has not reached the middle display yet.
        let secondEffects = move(
            &session,
            .right,
            style: .outline,
            reducesMotion: true,
            from: window,
            at: 0.01
        )
        let second = try XCTUnwrap(session.animation)
        XCTAssertEqual(
            secondEffects,
            [
                .discardPendingWrites(animationIdentifier: first.identifier),
                finalPlacement(
                    second,
                    CGRect(x: 2_100, y: 100, width: 500, height: 400),
                    resizing: true
                ),
            ]
        )

        XCTAssertEqual(
            session.writeDidFinish(
                .finalPlacement,
                animationIdentifier: first.identifier,
                succeeded: true
            ),
            []
        )
        XCTAssertEqual(session.animation, second)
        XCTAssertEqual(
            session.writeDidFinish(
                .finalPlacement,
                animationIdentifier: second.identifier,
                succeeded: true
            ),
            [.discardPendingWrites(animationIdentifier: second.identifier)]
        )
        XCTAssertNil(session.animation)
    }

    func testMovingBackBeforeTheWindowMovedPlacesItWithoutAnimating() throws {
        var session = Session()
        _ = move(&session, .right, from: window)
        let first = try XCTUnwrap(session.animation)

        let effects = move(&session, .left, from: window, at: 0.01)
        let second = try XCTUnwrap(session.animation)

        XCTAssertEqual(
            effects,
            [
                .discardPendingWrites(animationIdentifier: first.identifier),
                finalPlacement(second, window, resizing: true),
            ]
        )
        XCTAssertNil(session.animatingDisplay)
    }

    func testFocusChangeSettlesTheEarlierWindowAtItsDestination() throws {
        for reducesMotion in [false, true] {
            var session = Session()
            _ = move(&session, .right, reducesMotion: reducesMotion, from: window)
            let first = try XCTUnwrap(session.animation)

            let effects = move(
                &session,
                .right,
                reducesMotion: reducesMotion,
                window: "browser",
                from: window,
                at: 0.05
            )
            let second = try XCTUnwrap(session.animation)

            XCTAssertEqual(
                Array(effects.prefix(2)),
                [
                    .discardPendingWrites(animationIdentifier: first.identifier),
                    .write(
                        WindowMovementWrite(
                            window: "editor",
                            animationIdentifier: first.identifier,
                            purpose: .settle,
                            frame: first.destinationFrame,
                            mutations: first.finalPlacement
                        )
                    ),
                ],
                "reducesMotion: \(reducesMotion)"
            )
            XCTAssertEqual(second.window, "browser")
            XCTAssertEqual(second.startFrame, window)
            XCTAssertEqual(second.destinationDisplay, middle)
            XCTAssertEqual(
                session.writeDidFinish(
                    .settle,
                    animationIdentifier: first.identifier,
                    succeeded: true
                ),
                []
            )
            XCTAssertEqual(session.animation, second)
        }
    }

    func testDisplayChangeStopsOnlyWhenTheDestinationDisappears() throws {
        var session = Session()
        _ = move(&session, .right, style: .outline, from: window)
        let animation = try XCTUnwrap(session.animation)

        XCTAssertEqual(session.displaysDidChange([left, middle]), [])
        XCTAssertNotNil(session.outlineFrame)

        XCTAssertEqual(
            session.displaysDidChange([left, right]),
            [.discardPendingWrites(animationIdentifier: animation.identifier)]
        )
        XCTAssertNil(session.animation)
        XCTAssertNil(session.outlineFrame)
        XCTAssertNil(session.animatingDisplay)
    }

    func testMoveAfterTheDestinationDisappearedDoesNotSettleIt() throws {
        var session = Session()
        _ = move(&session, .right, from: window)
        let first = try XCTUnwrap(session.animation)

        // A missing destination outranks the focus change.
        let effects = move(
            &session,
            .right,
            window: "browser",
            from: window,
            displays: [left, right],
            at: 0.05
        )

        XCTAssertEqual(
            effects,
            [.discardPendingWrites(animationIdentifier: first.identifier)]
        )
        XCTAssertEqual(session.animation?.window, "browser")
        XCTAssertEqual(session.animation?.destinationDisplay, right)
    }

    func testFrameWriteFailureSettlesAtTheDestination() throws {
        var session = Session()
        _ = move(&session, .right, from: window)
        let animation = try XCTUnwrap(session.animation)
        _ = session.advance(to: 0.1)

        XCTAssertEqual(
            session.writeDidFinish(
                .frame,
                animationIdentifier: animation.identifier,
                succeeded: false
            ),
            [
                .discardPendingWrites(animationIdentifier: animation.identifier),
                settle(animation),
            ]
        )
        XCTAssertNil(session.animation)
    }

    func testFinalPlacementFailureStopsWithoutRetrying() throws {
        var session = Session()
        _ = move(&session, .right, from: window)
        let animation = try XCTUnwrap(session.animation)
        _ = session.advance(to: 0.2)

        XCTAssertEqual(
            session.writeDidFinish(
                .finalPlacement,
                animationIdentifier: animation.identifier,
                succeeded: false
            ),
            [.discardPendingWrites(animationIdentifier: animation.identifier)]
        )
        XCTAssertNil(session.animation)
    }

    func testShutdownSettlesAtTheDestination() throws {
        var session = Session()
        _ = move(&session, .right, style: .outline, from: window)
        let animation = try XCTUnwrap(session.animation)

        XCTAssertEqual(
            session.shutDown(),
            [
                .discardPendingWrites(animationIdentifier: animation.identifier),
                settle(animation),
            ]
        )
        XCTAssertNil(session.outlineFrame)
        XCTAssertEqual(session.shutDown(), [])
    }

    private func move(
        _ session: inout Session,
        _ direction: WindowMoveDirection,
        style: WindowMovementStyle = .live,
        reducesMotion: Bool = false,
        window: String = "editor",
        from frame: CGRect,
        displays: [DisplayGeometry]? = nil,
        at time: CFTimeInterval = 0,
        canResize: Bool = true
    ) -> [Effect] {
        session.move(
            direction,
            style: style,
            reducesMotion: reducesMotion,
            window: window,
            frame: frame,
            displays: displays ?? self.displays,
            at: time,
            canResize: { canResize }
        )
    }

    private func frameWrite(
        _ animation: Session.Animation,
        origin: CGPoint
    ) -> Effect {
        let frame = CGRect(origin: origin, size: animation.startFrame.size)
        return .write(
            WindowMovementWrite(
                window: animation.window,
                animationIdentifier: animation.identifier,
                purpose: .frame,
                frame: frame,
                mutations: [.position(origin)]
            )
        )
    }

    private func finalPlacement(
        _ animation: Session.Animation,
        _ frame: CGRect,
        resizing: Bool = false
    ) -> Effect {
        .write(
            WindowMovementWrite(
                window: animation.window,
                animationIdentifier: animation.identifier,
                purpose: .finalPlacement,
                frame: frame,
                mutations: resizing
                    ? [
                        .position(frame.origin),
                        .size(frame.size),
                        .position(frame.origin),
                    ]
                    : [.position(frame.origin)]
            )
        )
    }

    private func settle(_ animation: Session.Animation) -> Effect {
        .write(
            WindowMovementWrite(
                window: animation.window,
                animationIdentifier: animation.identifier,
                purpose: .settle,
                frame: animation.destinationFrame,
                mutations: animation.finalPlacement
            )
        )
    }

    private func assertFrame(
        _ actual: CGRect?,
        _ expected: CGRect,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let actual else {
            return XCTFail("Expected \(expected)", file: file, line: line)
        }
        for (actualValue, expectedValue) in [
            (actual.minX, expected.minX),
            (actual.minY, expected.minY),
            (actual.width, expected.width),
            (actual.height, expected.height),
        ] {
            XCTAssertEqual(
                actualValue,
                expectedValue,
                accuracy: 0.001,
                "\(actual) != \(expected)",
                file: file,
                line: line
            )
        }
    }
}

private func display(x: CGFloat) -> DisplayGeometry {
    let frame = CGRect(x: x, y: 0, width: 1_000, height: 800)
    return DisplayGeometry(frame: frame, visibleFrame: frame)
}
