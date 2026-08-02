import AppKit
import RufCore
import Sparkle

@MainActor
final class SoftwareUpdateController: NSObject {
    private let onStateChange: (SoftwareUpdateState) -> Void
    private var updater: SPUUpdater!
    private var downloadRequested = false
    private var activeVersion: String?
    private var installContinuation:
        CheckedContinuation<SPUUserUpdateChoice, Never>?

    private(set) var state = SoftwareUpdateState.idle {
        didSet {
            guard state != oldValue else {
                return
            }

            onStateChange(state)
        }
    }

    init(onStateChange: @escaping (SoftwareUpdateState) -> Void) {
        self.onStateChange = onStateChange
        super.init()
        updater = SPUUpdater(
            hostBundle: .main,
            applicationBundle: .main,
            userDriver: self,
            delegate: self
        )
    }

    func start() {
        do {
            try updater.start()
        } catch {
            showError(error)
        }
    }

    func performPrimaryAction() {
        switch state.primaryAction {
        case .check:
            downloadRequested = false
            updater.checkForUpdates()
        case .download:
            downloadRequested = true
            updater.checkForUpdates()
        case .installAndRelaunch:
            guard case let .readyToInstall(version) = state,
                  let installContinuation else {
                return
            }

            state = .installing(version: version)
            self.installContinuation = nil
            installContinuation.resume(returning: .install)
        case nil:
            break
        }
    }

    var canPerformPrimaryAction: Bool {
        switch state.primaryAction {
        case .check, .download:
            updater.canCheckForUpdates
        case .installAndRelaunch:
            installContinuation != nil
        case nil:
            false
        }
    }

    private func showError(_ error: Error) {
        state = .idle

        let alert = NSAlert(error: error)
        alert.messageText = "Ruf couldn't update."
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

extension SoftwareUpdateController: SPUUpdaterDelegate {
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        activeVersion = item.displayVersionString

        if case .checking = state {
            return
        }

        state = .available(version: item.displayVersionString)
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        if case .checking = state {
            state = .idle
        }
    }

    func updater(
        _ updater: SPUUpdater,
        didAbortWithError error: Error
    ) {
        if case .checking = state {
            state = .idle
        } else if case .downloading = state {
            showError(error)
        }
    }
}

extension SoftwareUpdateController: SPUUserDriver {
    func show(_ request: SPUUpdatePermissionRequest) async
        -> SUUpdatePermissionResponse {
        SUUpdatePermissionResponse(
            automaticUpdateChecks: true,
            automaticUpdateDownloading: false,
            sendSystemProfile: false
        )
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        state = .checking
    }

    func showUpdateFound(
        with appcastItem: SUAppcastItem,
        state updateState: SPUUserUpdateState
    ) async -> SPUUserUpdateChoice {
        let version = appcastItem.displayVersionString
        activeVersion = version

        guard !appcastItem.isInformationOnlyUpdate else {
            state = .idle
            return .dismiss
        }

        switch updateState.stage {
        case .notDownloaded:
            if downloadRequested {
                downloadRequested = false
                state = .downloading(version: version)
                return .install
            }

            state = .available(version: version)
            return .dismiss
        case .downloaded, .installing:
            state = .readyToInstall(version: version)
            return await withCheckedContinuation { continuation in
                installContinuation = continuation
            }
        @unknown default:
            state = .available(version: version)
            return .dismiss
        }
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}

    func showUpdateNotFoundWithError(_ error: Error) async {
        state = .idle
        let alert = NSAlert(error: error)
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    func showUpdaterError(_ error: Error) async {
        showError(error)
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        if let activeVersion {
            state = .downloading(version: activeVersion)
        }
    }

    func showDownloadDidReceiveExpectedContentLength(
        _ expectedContentLength: UInt64
    ) {}

    func showDownloadDidReceiveData(ofLength length: UInt64) {}

    func showDownloadDidStartExtractingUpdate() {}

    func showExtractionReceivedProgress(_ progress: Double) {}

    func showReadyToInstallAndRelaunch() async -> SPUUserUpdateChoice {
        guard let activeVersion else {
            state = .idle
            return .dismiss
        }

        state = .readyToInstall(version: activeVersion)
        return await withCheckedContinuation { continuation in
            installContinuation = continuation
        }
    }

    func showInstallingUpdate(
        withApplicationTerminated applicationTerminated: Bool,
        retryTerminatingApplication: @escaping () -> Void
    ) {
        if let activeVersion {
            state = .installing(version: activeVersion)
        }
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool) async {
        state = .idle
    }

    func dismissUpdateInstallation() {
        guard let installContinuation else {
            return
        }

        self.installContinuation = nil
        installContinuation.resume(returning: .dismiss)

        if let activeVersion {
            state = .available(version: activeVersion)
        } else {
            state = .idle
        }
    }
}
