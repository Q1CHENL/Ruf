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
