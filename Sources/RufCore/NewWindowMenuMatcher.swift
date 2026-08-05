import Foundation

private func normalizedMenuText(_ text: String) -> String {
    text
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased(with: Locale(identifier: "en_US_POSIX"))
}

public enum NewWindowMenuTitleMatcher {
    private static let supportedTitles: Set<String> = [
        "new window",
        "neues fenster",
        "新規ウインドウ",
        "新しいウィンドウ",
        "新建窗口",
        "新增視窗",
        "새로운 윈도우",
        "새 창",
    ]

    public static func matches(_ title: String) -> Bool {
        supportedTitles.contains(normalizedMenuText(title))
    }
}

public enum NewWindowMenuItemMatcher {
    public static func shouldPress(
        title: String?,
        isEnabled: Bool,
        hasChildren: Bool,
        isInsideNewWindowSubmenu: Bool,
        isInsideFileMenu: Bool,
        commandCharacter: String?,
        commandModifiers: UInt32?
    ) -> Bool {
        guard isEnabled, !hasChildren else {
            return false
        }

        if let title, NewWindowMenuTitleMatcher.matches(title) {
            return true
        }

        guard isInsideNewWindowSubmenu || isInsideFileMenu,
              commandModifiers == 0,
              let commandCharacter else {
            return false
        }

        return normalizedMenuText(commandCharacter) == "n"
    }
}

public enum NewWindowMenuSearchOutcome: Equatable, Sendable {
    case actionRequested
    case incomplete
    case noMatch
}

public enum NewWindowMenuSearchDecision {
    public static func shouldRetry(
        after outcome: NewWindowMenuSearchOutcome,
        hasTimeRemaining: Bool
    ) -> Bool {
        outcome == .incomplete && hasTimeRemaining
    }
}
