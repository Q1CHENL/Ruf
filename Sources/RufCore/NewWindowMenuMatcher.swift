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
    /// The item opens a new window: its title says so, or it is the plain
    /// Command-N item inside a New Window submenu.
    case newWindow
    /// A plain Command-N item directly in a top-level menu. In most
    /// localizations it is New Window, but it is pressed only when no
    /// `newWindow` item turns up.
    case shortcutFallback
    case none
}

public enum NewWindowMenuItemMatcher {
    /// Reads `commandShortcut` only for an item whose shortcut decides the
    /// match, since each read is another round trip to the application.
    public static func match(
        title: String?,
        isEnabled: Bool,
        hasChildren: Bool,
        isInsideNewWindowSubmenu: Bool,
        isDirectTopLevelMenuItem: Bool,
        commandShortcut: () -> (character: String?, modifiers: UInt32?)
    ) -> NewWindowMenuItemMatch {
        guard isEnabled, !hasChildren else {
            return .none
        }

        if let title, NewWindowMenuTitleMatcher.matches(title) {
            return .newWindow
        }

        guard isInsideNewWindowSubmenu || isDirectTopLevelMenuItem else {
            return .none
        }

        let shortcut = commandShortcut()
        guard shortcut.modifiers == 0,
              let character = shortcut.character,
              normalizedMenuText(character) == "n" else {
            return .none
        }

        return isInsideNewWindowSubmenu ? .newWindow : .shortcutFallback
    }
}

/// How much of a menu tree one traversal managed to read. Two identical
/// readings mean the tree has stopped changing under it.
public struct NewWindowMenuSearchCoverage: Equatable, Sendable {
    public let visited: Int
    public let queued: Int

    public init(visited: Int, queued: Int) {
        self.visited = visited
        self.queued = queued
    }
}

/// One traversal of an application's menu bar.
public struct NewWindowMenuSearchAttempt<Element> {
    /// An item that opens a new window.
    public let match: Element?
    /// A Command-N fallback found by this or an earlier attempt. The last
    /// attempt can start after the budget expired and read nothing, so a
    /// fallback has to outlive the attempt that found it.
    public let fallback: Element?
    /// Whether every element the search needed could be read.
    public let isComplete: Bool
    public let coverage: NewWindowMenuSearchCoverage

    public init(
        match: Element?,
        fallback: Element?,
        isComplete: Bool,
        coverage: NewWindowMenuSearchCoverage
    ) {
        self.match = match
        self.fallback = fallback
        self.isComplete = isComplete
        self.coverage = coverage
    }
}

public enum NewWindowMenuSearchStep<Element> {
    case press(Element)
    case retry
    case giveUp
}

extension NewWindowMenuSearchStep: Equatable where Element: Equatable {}

public enum NewWindowMenuSearchDecision {
    /// AX has no menu-tree-ready notification, so an incomplete reading is
    /// read again while the budget lasts, because the part it could not read
    /// may hold a better match than the Command-N fallback.
    public static func nextStep<Element>(
        after attempt: NewWindowMenuSearchAttempt<Element>,
        previousCoverage: NewWindowMenuSearchCoverage?,
        hasTimeRemaining: Bool
    ) -> NewWindowMenuSearchStep<Element> {
        if let match = attempt.match {
            return .press(match)
        }

        // Waiting for a better match is pointless once the reading is
        // complete, the budget is spent, or the tree reported the same
        // coverage twice and has stopped being built.
        if let fallback = attempt.fallback,
           attempt.isComplete
            || !hasTimeRemaining
            || attempt.coverage == previousCoverage {
            return .press(fallback)
        }

        return !attempt.isComplete && hasTimeRemaining ? .retry : .giveUp
    }
}
