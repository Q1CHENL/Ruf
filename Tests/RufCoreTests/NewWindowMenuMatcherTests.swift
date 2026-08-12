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
    func testClassifiesAnEnabledNewWindowLeafAsAnExactMatch() {
        XCTAssertEqual(
            NewWindowMenuItemMatcher.match(
                title: "New Window",
                isEnabled: true,
                hasChildren: false,
                isInsideNewWindowSubmenu: false,
                isDirectTopLevelMenuItem: false,
                commandCharacter: nil,
                commandModifiers: nil
            ),
            .exactTitle
        )
    }

    func testRejectsANewWindowSubmenuParent() {
        XCTAssertEqual(
            NewWindowMenuItemMatcher.match(
                title: "New Window",
                isEnabled: true,
                hasChildren: true,
                isInsideNewWindowSubmenu: false,
                isDirectTopLevelMenuItem: true,
                commandCharacter: nil,
                commandModifiers: nil
            ),
            .none
        )
    }

    func testClassifiesCommandNInsideANewWindowSubmenuAsFallback() {
        XCTAssertEqual(
            NewWindowMenuItemMatcher.match(
                title: "Built-in",
                isEnabled: true,
                hasChildren: false,
                isInsideNewWindowSubmenu: true,
                isDirectTopLevelMenuItem: false,
                commandCharacter: "n",
                commandModifiers: 0
            ),
            .shortcutFallback
        )
        XCTAssertEqual(
            NewWindowMenuItemMatcher.match(
                title: "New File",
                isEnabled: true,
                hasChildren: false,
                isInsideNewWindowSubmenu: false,
                isDirectTopLevelMenuItem: false,
                commandCharacter: "n",
                commandModifiers: 0
            ),
            .none
        )
    }

    func testClassifiesDirectTopLevelCommandNAsLocaleIndependentFallback() {
        XCTAssertEqual(
            NewWindowMenuItemMatcher.match(
                title: "Nouvelle fenêtre",
                isEnabled: true,
                hasChildren: false,
                isInsideNewWindowSubmenu: false,
                isDirectTopLevelMenuItem: true,
                commandCharacter: "n",
                commandModifiers: 0
            ),
            .shortcutFallback
        )

        XCTAssertEqual(
            NewWindowMenuItemMatcher.match(
                title: "Nouvelle fenêtre privée",
                isEnabled: true,
                hasChildren: false,
                isInsideNewWindowSubmenu: false,
                isDirectTopLevelMenuItem: true,
                commandCharacter: "n",
                commandModifiers: 1
            ),
            .none
        )
    }

    func testRejectsModifiedOrDisabledSubmenuCommands() {
        XCTAssertEqual(
            NewWindowMenuItemMatcher.match(
                title: "Built-in with Same Command",
                isEnabled: true,
                hasChildren: false,
                isInsideNewWindowSubmenu: true,
                isDirectTopLevelMenuItem: false,
                commandCharacter: "n",
                commandModifiers: 1
            ),
            .none
        )
        XCTAssertEqual(
            NewWindowMenuItemMatcher.match(
                title: "Built-in",
                isEnabled: false,
                hasChildren: false,
                isInsideNewWindowSubmenu: true,
                isDirectTopLevelMenuItem: false,
                commandCharacter: "n",
                commandModifiers: 0
            ),
            .none
        )
    }
}

final class NewWindowMenuSearchDecisionTests: XCTestCase {
    func testDefersFallbackWhileAnIncompleteSearchCanRetry() {
        XCTAssertEqual(
            NewWindowMenuSearchDecision.deferredDecision(
                hasFallback: true,
                wasIncomplete: true,
                hasTimeRemaining: true
            ),
            .reportIncomplete
        )
        XCTAssertEqual(
            NewWindowMenuSearchDecision.deferredDecision(
                hasFallback: true,
                wasIncomplete: true,
                hasTimeRemaining: false
            ),
            .requestFallback
        )
        XCTAssertEqual(
            NewWindowMenuSearchDecision.deferredDecision(
                hasFallback: true,
                wasIncomplete: false,
                hasTimeRemaining: true
            ),
            .requestFallback
        )
    }

    func testRetriesIncompleteSearchesAndFailedActionsWhileTimeRemains() {
        XCTAssertTrue(
            NewWindowMenuSearchDecision.shouldRetry(
                after: .incomplete,
                hasTimeRemaining: true
            )
        )
        XCTAssertFalse(
            NewWindowMenuSearchDecision.shouldRetry(
                after: .incomplete,
                hasTimeRemaining: false
            )
        )
        XCTAssertTrue(
            NewWindowMenuSearchDecision.shouldRetry(
                after: .actionFailed,
                hasTimeRemaining: true
            )
        )
        XCTAssertFalse(
            NewWindowMenuSearchDecision.shouldRetry(
                after: .actionFailed,
                hasTimeRemaining: false
            )
        )
        XCTAssertFalse(
            NewWindowMenuSearchDecision.shouldRetry(
                after: .actionRequested,
                hasTimeRemaining: true
            )
        )
        XCTAssertFalse(
            NewWindowMenuSearchDecision.shouldRetry(
                after: .noMatch,
                hasTimeRemaining: true
            )
        )
    }
}
