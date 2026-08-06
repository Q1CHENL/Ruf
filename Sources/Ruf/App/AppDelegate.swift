import AppKit
import RufCore
import ServiceManagement
import Sparkle

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let catalog = ApplicationCatalog()
    private let focusedWindowMover = FocusedWindowMover()
    private let model = SwitcherModel()
    private let preferences = AppPreferences()

    private lazy var panelController = SwitcherPanelController(
        model: model,
        onChoose: { [weak self] index in
            self?.model.select(index)
            self?.commitSelection()
        }
    )

    private lazy var keyboardEventTap = KeyboardEventTap(
        capturesCommandTab: preferences.switcherMode == .ruf
    ) { [weak self] command in
        self?.handle(command)
    }

    private lazy var settingsWindowController = SettingsWindowController(
        preferences: preferences,
        onSwitcherModeChanged: { [weak self] in
            self?.switcherModeDidChange()
        }
    )

    private lazy var softwareUpdateController = SPUStandardUpdaterController(
        startingUpdater: false,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    private var statusItem: NSStatusItem?
    private var softwareUpdateMenuItem: NSMenuItem?
    private var accessibilityMenuItem: NSMenuItem?
    private weak var aboutPanel: NSPanel?
    private var permissionMonitor: Timer?
    private var remainingPermissionChecks = 0
    private var snapshotTask: Task<Void, Never>?
    private var openSpan: PerformanceLog.Span?
    private var loadingSession = SwitcherLoadingSession()
    private var newWindowTasks: [UUID: Task<Void, Never>] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        enableLaunchAtLoginByDefaultIfNeeded()
        installStatusItem()
        panelController.prepare(itemCount: 0)
        applySwitcherMode()
        softwareUpdateController.startUpdater()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        if !keyboardEventTap.isRunning {
            refreshKeyboardCaptureState(
                accessibilityGranted: AccessibilityPermission.isGranted
            )
        }
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        settingsWindowController.show()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        snapshotTask?.cancel()
        cancelNewWindowRequests()
        stopPermissionMonitoring()
        keyboardEventTap.stop()
        focusedWindowMover.stop()
    }

    private func handle(_ command: KeyboardCommand) {
        switch command {
        case let .switcher(action):
            handleSwitcher(action)
        case let .moveFocusedWindow(direction):
            focusedWindowMover.move(direction)
        }
    }

    private func handleSwitcher(_ command: SwitcherAction) {
        switch loadingSession.receive(command) {
        case .queued:
            return
        case .cancelLoading:
            cancelSwitcher()
            return
        case .handleImmediately:
            break
        }

        switch command {
        case let .cycle(backwards):
            if model.isPresented {
                model.move(backwards ? .backward : .forward)
            } else {
                loadTargets(backwards: backwards)
            }
        case let .move(move):
            model.move(move)
        case .openNewWindow:
            openNewWindow()
        case .quitApplication:
            quitSelectedApplication()
        case .commit:
            commitSelection()
        case .cancel:
            cancelSwitcher()
        }
    }

    private func loadTargets(backwards: Bool) {
        loadingSession.beginLoading()
        // Spans the whole gesture the user actually feels: the keyboard command
        // that opens the switcher through to the panel reaching the screen.
        openSpan = PerformanceLog.begin("switcher.open")
        snapshotTask = Task { [weak self] in
            guard let self else {
                return
            }

            let targets = await catalog.snapshot()
            guard !Task.isCancelled else {
                return
            }

            finishLoadingTargets(targets, backwards: backwards)
        }
    }

    private func finishLoadingTargets(
        _ targets: [SwitchTarget],
        backwards: Bool
    ) {
        snapshotTask = nil
        let replayPlan = loadingSession.finishLoading()

        guard !targets.isEmpty else {
            endOpenSpan("aborted targets=0")
            keyboardEventTap.resetInputSession()
            return
        }

        let beginSpan = PerformanceLog.begin("switcher.begin")
        model.begin(with: targets, backwards: backwards)
        PerformanceLog.end(beginSpan)

        for action in replayPlan.beforePresentation {
            handleSwitcher(action)
            guard model.isPresented else {
                endOpenSpan("dismissed before presentation")
                return
            }
        }

        panelController.show(itemCount: targets.count)
        endOpenSpan("targets=\(targets.count)")

        for action in replayPlan.afterPresentation {
            handleSwitcher(action)
            if case .openNewWindow = action {
                return
            }
            guard model.isPresented else {
                return
            }
        }
    }

    private func commitSelection() {
        keyboardEventTap.resetInputSession()
        guard let target = takeSelection() else {
            return
        }

        switch target.kind {
        case .application:
            target.item.application.activate(options: [.activateAllWindows])
        case let .applicationWindow(window), let .window(window):
            ApplicationWindowService.activate(
                window,
                in: target.item.application
            )
        case .reopenApplication:
            ApplicationWindowService.reopen(target.item.application)
        }
    }

    private func openNewWindow() {
        guard let target = takeSelection() else {
            return
        }

        openNewWindow(for: target)
    }

    private func openNewWindow(for target: SwitchTarget) {
        if case .reopenApplication = target.kind {
            ApplicationWindowService.reopen(target.item.application)
            return
        }

        let requestID = UUID()
        newWindowTasks[requestID] = Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            defer {
                newWindowTasks[requestID] = nil
            }

            let application = target.item.application
            switch target.kind {
            case let .applicationWindow(window), let .window(window):
                ApplicationWindowService.activate(window, in: application)
            case .application, .reopenApplication:
                break
            }

            let result = await ApplicationWindowService.openNewWindow(
                in: application
            )
            guard !Task.isCancelled,
                  case .unavailable = result else {
                return
            }

            NSSound.beep()
        }
    }

    private func cancelNewWindowRequests() {
        for task in newWindowTasks.values {
            task.cancel()
        }
        newWindowTasks.removeAll()
    }

    private func quitSelectedApplication() {
        guard let target = takeSelection() else {
            return
        }

        if !target.item.application.terminate() {
            NSSound.beep()
        }
    }

    private func takeSelection() -> SwitchTarget? {
        let target = model.finish()
        panelController.hide()
        return target
    }

    private func endOpenSpan(_ detail: String) {
        guard let openSpan else {
            return
        }

        PerformanceLog.end(openSpan, detail)
        self.openSpan = nil
    }

    private func cancelSwitcher() {
        snapshotTask?.cancel()
        snapshotTask = nil
        endOpenSpan("cancelled")
        loadingSession.cancelLoading()
        keyboardEventTap.resetInputSession()
        model.cancel()
        panelController.cancel()
    }

    private func installStatusItem() {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "square.grid.2x2",
                accessibilityDescription: "Ruf"
            )
            button.toolTip = "Ruf"

            if button.image == nil {
                button.title = "▦"
            }
        }

        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        menu.addItem(
            withTitle: "About Ruf",
            action: #selector(showAbout),
            keyEquivalent: ""
        ).target = self
        let softwareUpdateMenuItem = menu.addItem(
            withTitle: "Check for Updates…",
            action: #selector(
                SPUStandardUpdaterController.checkForUpdates(_:)
            ),
            keyEquivalent: ""
        )
        softwareUpdateMenuItem.target = softwareUpdateController
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Settings…",
            action: #selector(showSettings),
            keyEquivalent: ","
        ).target = self
        let accessibilityMenuItem = menu.addItem(
            withTitle: "Enable Accessibility…",
            action: #selector(enableAccessibility),
            keyEquivalent: ""
        )
        accessibilityMenuItem.target = self
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Quit Ruf",
            action: #selector(quit),
            keyEquivalent: "q"
        ).target = self

        statusItem.menu = menu
        self.statusItem = statusItem
        self.softwareUpdateMenuItem = softwareUpdateMenuItem
        self.accessibilityMenuItem = accessibilityMenuItem
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        updateSoftwareUpdateMenuItem()
        updateAccessibilityMenuItem(
            accessibilityGranted: AccessibilityPermission.isGranted
        )
    }

    private func updateSoftwareUpdateMenuItem() {
        softwareUpdateMenuItem?.isEnabled =
            softwareUpdateController.updater.canCheckForUpdates
    }

    private func updateAccessibilityMenuItem(accessibilityGranted: Bool) {
        if keyboardEventTap.isRunning {
            accessibilityMenuItem?.isHidden = true
        } else {
            accessibilityMenuItem?.isHidden = false
            accessibilityMenuItem?.title = accessibilityGranted
                ? "Retry Ruf"
                : "Enable Accessibility…"
        }
    }

    private func refreshKeyboardCaptureState(accessibilityGranted: Bool) {
        keyboardEventTap.setCapturesCommandTab(
            preferences.switcherMode == .ruf
        )

        if accessibilityGranted {
            stopPermissionMonitoring()
            keyboardEventTap.start()
        } else {
            keyboardEventTap.stop()
        }

        updateAccessibilityMenuItem(accessibilityGranted: accessibilityGranted)
    }

    private func applySwitcherMode() {
        if preferences.switcherMode == .system,
           model.isPresented || loadingSession.isLoading {
            cancelSwitcher()
        }

        let accessibilityGranted = AccessibilityPermission.isGranted
        refreshKeyboardCaptureState(accessibilityGranted: accessibilityGranted)

        if !accessibilityGranted {
            requestAccessibility(openSystemSettings: false)
        }
    }

    private func requestAccessibility(openSystemSettings: Bool) {
        AccessibilityPermission.request()

        if openSystemSettings {
            AccessibilityPermission.openSystemSettings()
        }

        startPermissionMonitoring()
    }

    private func startPermissionMonitoring() {
        let accessibilityGranted = AccessibilityPermission.isGranted
        if accessibilityGranted {
            refreshKeyboardCaptureState(
                accessibilityGranted: accessibilityGranted
            )
            return
        }

        stopPermissionMonitoring()
        remainingPermissionChecks = 120

        let timer = Timer(
            timeInterval: 1,
            target: self,
            selector: #selector(checkAccessibilityPermission(_:)),
            userInfo: nil,
            repeats: true
        )
        permissionMonitor = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopPermissionMonitoring() {
        permissionMonitor?.invalidate()
        permissionMonitor = nil
        remainingPermissionChecks = 0
    }

    @objc
    private func checkAccessibilityPermission(_ timer: Timer) {
        guard timer === permissionMonitor else {
            timer.invalidate()
            return
        }

        let accessibilityGranted = AccessibilityPermission.isGranted
        if accessibilityGranted {
            refreshKeyboardCaptureState(
                accessibilityGranted: accessibilityGranted
            )
            return
        }

        remainingPermissionChecks -= 1
        if remainingPermissionChecks <= 0 {
            stopPermissionMonitoring()
        }

        updateAccessibilityMenuItem(accessibilityGranted: accessibilityGranted)
    }

    private func switcherModeDidChange() {
        applySwitcherMode()
    }

    private func enableLaunchAtLoginByDefaultIfNeeded() {
        guard preferences.shouldEnableLaunchAtLoginByDefault else {
            return
        }

        let service = SMAppService.mainApp

        switch service.status {
        case .enabled, .requiresApproval:
            preferences.markLaunchAtLoginConfigured()
        case .notRegistered:
            do {
                try service.register()
                preferences.markLaunchAtLoginConfigured()
            } catch {
                return
            }
        case .notFound:
            return
        @unknown default:
            return
        }
    }

    @objc
    private func showAbout() {
        let existingWindowIdentifiers = Set(
            NSApp.windows.map(ObjectIdentifier.init)
        )
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        let credits = NSAttributedString(
            string: "GitHub",
            attributes: [
                .link: "https://github.com/Q1CHENL/Ruf",
                .paragraphStyle: paragraphStyle,
            ]
        )

        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(
            options: [
                .version: "",
                .credits: credits,
            ]
        )

        if aboutPanel == nil {
            aboutPanel = NSApp.windows.first { window in
                window is NSPanel
                    && !existingWindowIdentifiers.contains(
                        ObjectIdentifier(window)
                    )
            } as? NSPanel
        }

        aboutPanel?.makeKeyAndOrderFront(nil)
        let closeButton = aboutPanel?
            .standardWindowButton(.closeButton)
        closeButton?.keyEquivalent = "w"
        closeButton?.keyEquivalentModifierMask = .command
    }

    @objc
    private func showSettings() {
        settingsWindowController.show()
    }

    @objc
    private func enableAccessibility() {
        let accessibilityGranted = AccessibilityPermission.isGranted
        if accessibilityGranted {
            refreshKeyboardCaptureState(
                accessibilityGranted: accessibilityGranted
            )
        } else {
            requestAccessibility(openSystemSettings: true)
        }
    }

    @objc
    private func quit() {
        NSApp.terminate(nil)
    }
}
