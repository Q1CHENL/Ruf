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

public enum NewWindowMenuItemMatch: Equatable, Sendable {
    case exactTitle
    case shortcutFallback
    case none
}

public enum NewWindowMenuItemMatcher {
    public static func match(
        title: String?,
        isEnabled: Bool,
        hasChildren: Bool,
        isInsideNewWindowSubmenu: Bool,
        isDirectTopLevelMenuItem: Bool,
        commandCharacter: String?,
        commandModifiers: UInt32?
    ) -> NewWindowMenuItemMatch {
        guard isEnabled, !hasChildren else {
            return .none
        }

        if let title, NewWindowMenuTitleMatcher.matches(title) {
            return .exactTitle
        }

        guard isInsideNewWindowSubmenu || isDirectTopLevelMenuItem,
              commandModifiers == 0,
              let commandCharacter else {
            return .none
        }

        return normalizedMenuText(commandCharacter) == "n"
            ? .shortcutFallback
            : .none
    }
}

public enum NewWindowMenuSearchOutcome: Equatable, Sendable {
    case actionRequested
    case actionFailed
    case incomplete
    case noMatch
}

public enum NewWindowMenuDeferredDecision: Equatable, Sendable {
    case requestFallback
    case reportIncomplete
    case noMatch
}

public enum NewWindowMenuSearchDecision {
    public static func deferredDecision(
        hasFallback: Bool,
        wasIncomplete: Bool,
        hasTimeRemaining: Bool
    ) -> NewWindowMenuDeferredDecision {
        if wasIncomplete, hasTimeRemaining {
            return .reportIncomplete
        }

        if hasFallback {
            return .requestFallback
        }

        return wasIncomplete ? .reportIncomplete : .noMatch
    }

    public static func shouldRetry(
        after outcome: NewWindowMenuSearchOutcome,
        hasTimeRemaining: Bool
    ) -> Bool {
        switch outcome {
        case .actionFailed, .incomplete:
            hasTimeRemaining
        case .actionRequested, .noMatch:
            false
        }
    }

    // Polling waits for a menu tree that is still being built. A tree that
    // reports identical coverage twice has stopped being built, and the part
    // still reading as incomplete will stay that way, so spending the rest of
    // the budget on it only delays a match already in hand.
    public static func shouldPressDeferredFallback(
        hasFallback: Bool,
        coverageRepeated: Bool
    ) -> Bool {
        hasFallback && coverageRepeated
    }
}
