import XCTest
@testable import RufCore

final class NewWindowMenuTitleMatcherTests: XCTestCase {
    func testMatchesSupportedNewWindowTitles() {
        for title in ["New Window", "new window", "新建窗口", "新增視窗"] {
            XCTAssertTrue(
                NewWindowMenuTitleMatcher.matches(title),
                "Expected to match \(title)"
            )
        }
    }

    func testMatchesGermanJapaneseAndKoreanNewWindowTitles() {
        for title in [
            "Neues Fenster",
            "新規ウインドウ",
            "新しいウィンドウ",
            "새로운 윈도우",
            "새 창",
        ] {
            XCTAssertTrue(
                NewWindowMenuTitleMatcher.matches(title),
                "Expected to match \(title)"
            )
        }
    }

    func testIgnoresSurroundingWhitespace() {
        XCTAssertTrue(NewWindowMenuTitleMatcher.matches("  New Window\n"))
    }

    func testRejectsOtherWindowAndDocumentActions() {
        for title in [
            "New File",
            "New Text File",
            "New Incognito Window",
            "New Private Window",
            "Neues Inkognitofenster",
            "Neues privates Fenster",
            "新規シークレット ウインドウ",
            "새 시크릿 창",
            "Reopen Closed Window",
            "Open in New Window",
        ] {
            XCTAssertFalse(
                NewWindowMenuTitleMatcher.matches(title),
                "Expected to reject \(title)"
            )
        }
    }
}

final class NewWindowMenuItemMatcherTests: XCTestCase {
    func testClassifiesAnEnabledNewWindowLeafAsAMatch() {
        XCTAssertEqual(
            match(title: "New Window"),
            .newWindow
        )
    }

    func testRejectsANewWindowSubmenuParent() {
        XCTAssertEqual(
            match(
                title: "New Window",
                hasChildren: true,
                isDirectTopLevelMenuItem: true
            ),
            .none
        )
    }

    func testClassifiesCommandNInsideANewWindowSubmenuAsAMatch() {
        XCTAssertEqual(
            match(
                title: "Built-in",
                isInsideNewWindowSubmenu: true,
                shortcut: ("n", 0)
            ),
            .newWindow
        )
        XCTAssertEqual(
            match(title: "New File", shortcut: ("n", 0)),
            .none
        )
    }

    func testClassifiesDirectTopLevelCommandNAsLocaleIndependentFallback() {
        XCTAssertEqual(
            match(
                title: "Nouvelle fenêtre",
                isDirectTopLevelMenuItem: true,
                shortcut: ("n", 0)
            ),
            .shortcutFallback
        )

        XCTAssertEqual(
            match(
                title: "Nouvelle fenêtre privée",
                isDirectTopLevelMenuItem: true,
                shortcut: ("n", 1)
            ),
            .none
        )
    }

    func testRejectsModifiedOrDisabledSubmenuCommands() {
        XCTAssertEqual(
            match(
                title: "Built-in with Same Command",
                isInsideNewWindowSubmenu: true,
                shortcut: ("n", 1)
            ),
            .none
        )
        XCTAssertEqual(
            match(
                title: "Built-in",
                isEnabled: false,
                isInsideNewWindowSubmenu: true,
                shortcut: ("n", 0)
            ),
            .none
        )
    }

    func testReadsTheShortcutOnlyWhenItDecidesTheMatch() {
        var reads = 0
        let shortcut = { () -> (character: String?, modifiers: UInt32?) in
            reads += 1
            return ("n", 0)
        }

        for (title, isInsideNewWindowSubmenu, isDirectTopLevelMenuItem) in [
            ("New Window", true, true),
            ("Close", false, false),
        ] {
            _ = NewWindowMenuItemMatcher.match(
                title: title,
                isEnabled: true,
                hasChildren: false,
                isInsideNewWindowSubmenu: isInsideNewWindowSubmenu,
                isDirectTopLevelMenuItem: isDirectTopLevelMenuItem,
                commandShortcut: shortcut
            )
        }
        XCTAssertEqual(reads, 0)

        _ = NewWindowMenuItemMatcher.match(
            title: "Nouvelle fenêtre",
            isEnabled: true,
            hasChildren: false,
            isInsideNewWindowSubmenu: false,
            isDirectTopLevelMenuItem: true,
            commandShortcut: shortcut
        )
        XCTAssertEqual(reads, 1)
    }

    private func match(
        title: String?,
        isEnabled: Bool = true,
        hasChildren: Bool = false,
        isInsideNewWindowSubmenu: Bool = false,
        isDirectTopLevelMenuItem: Bool = false,
        shortcut: (character: String?, modifiers: UInt32?) = (nil, nil)
    ) -> NewWindowMenuItemMatch {
        NewWindowMenuItemMatcher.match(
            title: title,
            isEnabled: isEnabled,
            hasChildren: hasChildren,
            isInsideNewWindowSubmenu: isInsideNewWindowSubmenu,
            isDirectTopLevelMenuItem: isDirectTopLevelMenuItem,
            commandShortcut: { shortcut }
        )
    }
}

final class NewWindowMenuSearchDecisionTests: XCTestCase {
    func testPressesAMatchEvenFromAnIncompleteReading() {
        XCTAssertEqual(
            nextStep(match: "match", fallback: "fallback", isComplete: false),
            .press("match")
        )
    }

    func testGivesUpOnACompleteReadingWithoutAnyItem() {
        XCTAssertEqual(nextStep(isComplete: true), .giveUp)
    }

    func testPressesTheFallbackOnceTheReadingIsComplete() {
        XCTAssertEqual(
            nextStep(fallback: "fallback", isComplete: true),
            .press("fallback")
        )
    }

    func testRereadsAnIncompleteMenuWhileTimeRemains() {
        XCTAssertEqual(nextStep(isComplete: false), .retry)
        XCTAssertEqual(
            nextStep(fallback: "fallback", isComplete: false),
            .retry
        )
    }

    // The final attempt can start after the budget expired and fail to read
    // even the menu bar, so its reading is empty. The fallback found by an
    // earlier attempt is still the best answer.
    func testPressesTheFallbackWhenTheBudgetExpiresOnAnIncompleteReading() {
        XCTAssertEqual(
            nextStep(
                fallback: "fallback",
                isComplete: false,
                coverage: coverage(0, 0),
                previousCoverage: coverage(12, 40),
                hasTimeRemaining: false
            ),
            .press("fallback")
        )
        XCTAssertEqual(
            nextStep(isComplete: false, hasTimeRemaining: false),
            .giveUp
        )
    }

    func testPressesTheFallbackOnceTheCoverageStopsChanging() {
        XCTAssertEqual(
            nextStep(
                fallback: "fallback",
                isComplete: false,
                coverage: coverage(12, 40),
                previousCoverage: coverage(12, 40)
            ),
            .press("fallback")
        )

        // A tree that is still growing may yet expose the New Window item.
        XCTAssertEqual(
            nextStep(
                fallback: "fallback",
                isComplete: false,
                coverage: coverage(18, 52),
                previousCoverage: coverage(12, 40)
            ),
            .retry
        )

        // Without a fallback there is nothing to settle for.
        XCTAssertEqual(
            nextStep(
                isComplete: false,
                coverage: coverage(12, 40),
                previousCoverage: coverage(12, 40)
            ),
            .retry
        )
    }

    private func nextStep(
        match: String? = nil,
        fallback: String? = nil,
        isComplete: Bool,
        coverage: NewWindowMenuSearchCoverage = .init(visited: 1, queued: 1),
        previousCoverage: NewWindowMenuSearchCoverage? = nil,
        hasTimeRemaining: Bool = true
    ) -> NewWindowMenuSearchStep<String> {
        NewWindowMenuSearchDecision.nextStep(
            after: NewWindowMenuSearchAttempt(
                match: match,
                fallback: fallback,
                isComplete: isComplete,
                coverage: coverage
            ),
            previousCoverage: previousCoverage,
            hasTimeRemaining: hasTimeRemaining
        )
    }

    private func coverage(
        _ visited: Int,
        _ queued: Int
    ) -> NewWindowMenuSearchCoverage {
        NewWindowMenuSearchCoverage(visited: visited, queued: queued)
    }
}
