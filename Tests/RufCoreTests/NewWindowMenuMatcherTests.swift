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
    func testMatchesAnEnabledNewWindowLeaf() {
        XCTAssertTrue(
            NewWindowMenuItemMatcher.shouldPress(
                title: "New Window",
                isEnabled: true,
                hasChildren: false,
                isInsideNewWindowSubmenu: false,
                commandCharacter: nil,
                commandModifiers: nil
            )
        )
    }

    func testRejectsANewWindowSubmenuParent() {
        XCTAssertFalse(
            NewWindowMenuItemMatcher.shouldPress(
                title: "New Window",
                isEnabled: true,
                hasChildren: true,
                isInsideNewWindowSubmenu: false,
                commandCharacter: nil,
                commandModifiers: nil
            )
        )
    }

    func testMatchesCommandNOnlyInsideANewWindowSubmenu() {
        XCTAssertTrue(
            NewWindowMenuItemMatcher.shouldPress(
                title: "Built-in",
                isEnabled: true,
                hasChildren: false,
                isInsideNewWindowSubmenu: true,
                commandCharacter: "n",
                commandModifiers: 0
            )
        )
        XCTAssertFalse(
            NewWindowMenuItemMatcher.shouldPress(
                title: "New File",
                isEnabled: true,
                hasChildren: false,
                isInsideNewWindowSubmenu: false,
                commandCharacter: "n",
                commandModifiers: 0
            )
        )
    }

    func testRejectsModifiedOrDisabledSubmenuCommands() {
        XCTAssertFalse(
            NewWindowMenuItemMatcher.shouldPress(
                title: "Built-in with Same Command",
                isEnabled: true,
                hasChildren: false,
                isInsideNewWindowSubmenu: true,
                commandCharacter: "n",
                commandModifiers: 1
            )
        )
        XCTAssertFalse(
            NewWindowMenuItemMatcher.shouldPress(
                title: "Built-in",
                isEnabled: false,
                hasChildren: false,
                isInsideNewWindowSubmenu: true,
                commandCharacter: "n",
                commandModifiers: 0
            )
        )
    }
}

final class NewWindowMenuSearchDecisionTests: XCTestCase {
    func testRetriesOnlyIncompleteSearchesWhileTimeRemains() {
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
