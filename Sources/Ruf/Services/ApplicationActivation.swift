import AppKit

@MainActor
enum ApplicationActivation {
    private static let activationTimeout: Duration = .seconds(1)

    static func activate(_ application: NSRunningApplication) async -> Bool {
        if application.isActive {
            return true
        }

        return await Waiter(application: application).wait()
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

        func wait() async -> Bool {
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

                if !application.activate(options: []) {
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
