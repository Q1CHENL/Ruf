public struct SwitcherActionReplayPlan: Equatable, Sendable {
    public let beforePresentation: [SwitcherAction]
    public let afterPresentation: [SwitcherAction]

    public init(pendingActions: [SwitcherAction]) {
        guard let presentationBoundary = pendingActions.firstIndex(where: {
            if case .openNewWindow = $0 {
                return true
            }
            return false
        }) else {
            beforePresentation = pendingActions
            afterPresentation = []
            return
        }

        beforePresentation = Array(pendingActions[..<presentationBoundary])
        afterPresentation = Array(pendingActions[presentationBoundary...])
    }
}

public enum SwitcherLoadingDisposition: Equatable, Sendable {
    case handleImmediately
    case queued
    case cancelLoading
}

public struct SwitcherLoadingSession: Sendable {
    public private(set) var isLoading = false
    private var pendingActions: [SwitcherAction] = []

    public init() {}

    public mutating func beginLoading() {
        isLoading = true
        pendingActions = []
    }

    public mutating func receive(
        _ action: SwitcherAction
    ) -> SwitcherLoadingDisposition {
        guard isLoading else {
            return .handleImmediately
        }

        if case .cancel = action {
            cancelLoading()
            return .cancelLoading
        }

        pendingActions.append(action)
        return .queued
    }

    public mutating func finishLoading() -> SwitcherActionReplayPlan {
        let plan = SwitcherActionReplayPlan(pendingActions: pendingActions)
        cancelLoading()
        return plan
    }

    public mutating func cancelLoading() {
        isLoading = false
        pendingActions = []
    }
}
