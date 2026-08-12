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

public struct SwitcherGestureActions: Equatable, Sendable {
    public let gestureID: UInt64
    public private(set) var actions: [SwitcherAction]

    public init(gestureID: UInt64, actions: [SwitcherAction]) {
        self.gestureID = gestureID
        self.actions = actions
    }

    mutating func append(_ action: SwitcherAction) {
        actions.append(action)
    }
}

public struct SwitcherLoadingSession: Sendable {
    private var activeGesture: SwitcherGestureActions?
    private var deferredGestures: [SwitcherGestureActions] = []

    public init() {}

    public var isLoading: Bool {
        activeGesture != nil
    }

    public mutating func beginLoading(for gestureID: UInt64) {
        activeGesture = SwitcherGestureActions(
            gestureID: gestureID,
            actions: []
        )
    }

    public mutating func receive(
        _ command: SwitcherCommand
    ) -> SwitcherLoadingDisposition {
        guard let activeGesture else {
            return .handleImmediately
        }

        guard command.gestureID == activeGesture.gestureID else {
            deferCommand(command)
            return .queued
        }

        if case .cancel = command.action {
            finishActiveLoading()
            return .cancelLoading
        }

        self.activeGesture?.append(command.action)
        return .queued
    }

    public mutating func finishLoading(
        for gestureID: UInt64
    ) -> SwitcherActionReplayPlan? {
        guard let activeGesture,
              activeGesture.gestureID == gestureID else {
            return nil
        }

        let plan = SwitcherActionReplayPlan(
            pendingActions: activeGesture.actions
        )
        finishActiveLoading()
        return plan
    }

    public mutating func takeNextGesture() -> SwitcherGestureActions? {
        guard !deferredGestures.isEmpty else {
            return nil
        }

        return deferredGestures.removeFirst()
    }

    public mutating func cancelLoading() {
        finishActiveLoading()
        deferredGestures = []
    }

    private mutating func deferCommand(_ command: SwitcherCommand) {
        if case .cancel = command.action {
            deferredGestures.removeAll {
                $0.gestureID == command.gestureID
            }
            return
        }

        if deferredGestures.last?.gestureID == command.gestureID {
            deferredGestures[deferredGestures.count - 1].append(command.action)
        } else {
            deferredGestures.append(
                SwitcherGestureActions(
                    gestureID: command.gestureID,
                    actions: [command.action]
                )
            )
        }
    }

    private mutating func finishActiveLoading() {
        activeGesture = nil
    }
}
