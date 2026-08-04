import AppKit

@MainActor
enum ApplicationActivation {
    private static let activationTimeout: Duration = .seconds(1)

    static func waitUntilCurrentApplicationIsActive() async -> Bool {
        await Waiter(application: .current).wait()
    }

    static func transferTo(_ application: NSRunningApplication) async -> Bool {
        if application.isActive {
            return true
        }

        let currentApplication = NSRunningApplication.current
        guard currentApplication.isActive, NSApp.isActive else {
            return false
        }

        return await Waiter(application: application).wait(
            request: .transferFromCurrentApplication
        )
    }

    private enum Request {
        case none
        case transferFromCurrentApplication
    }

    @MainActor
    private final class Waiter: @unchecked Sendable {
        private let application: NSRunningApplication
        private let notificationCenter = NSWorkspace.shared.notificationCenter
        private var observer: NSObjectProtocol?
        private var timeoutTask: Task<Void, Never>?
        private var continuation: CheckedContinuation<Bool, Never>?

        init(application: NSRunningApplication) {
            self.application = application
        }

        func wait(request: Request = .none) async -> Bool {
            if application.isActive {
                return true
            }

            return await withCheckedContinuation { continuation in
                self.continuation = continuation
                observer = notificationCenter.addObserver(
                    forName: NSWorkspace.didActivateApplicationNotification,
                    object: nil,
                    queue: .main
                ) { [weak self] notification in
                    let processIdentifier = (
                        notification.userInfo?[
                            NSWorkspace.applicationUserInfoKey
                        ] as? NSRunningApplication
                    )?.processIdentifier
                    MainActor.assumeIsolated {
                        self?.applicationDidActivate(processIdentifier)
                    }
                }

                if !makeRequest(request) {
                    finish(false)
                    return
                }

                guard self.continuation != nil else {
                    return
                }

                if application.isActive {
                    finish(true)
                    return
                }

                timeoutTask = Task { @MainActor [weak self] in
                    do {
                        try await Task.sleep(for: activationTimeout)
                    } catch {
                        return
                    }

                    guard let self else {
                        return
                    }
                    finish(application.isActive)
                }
            }
        }

        private func makeRequest(_ request: Request) -> Bool {
            switch request {
            case .none:
                return true
            case .transferFromCurrentApplication:
                let currentApplication = NSRunningApplication.current
                NSApp.yieldActivation(to: application)
                return application.activate(
                    from: currentApplication,
                    options: []
                )
            }
        }

        private func applicationDidActivate(_ processIdentifier: pid_t?) {
            guard processIdentifier == application.processIdentifier else {
                return
            }

            finish(true)
        }

        private func finish(_ result: Bool) {
            guard let continuation else {
                return
            }

            self.continuation = nil
            if let observer {
                notificationCenter.removeObserver(observer)
            }
            observer = nil
            timeoutTask?.cancel()
            timeoutTask = nil
            continuation.resume(returning: result)
        }
    }
}
