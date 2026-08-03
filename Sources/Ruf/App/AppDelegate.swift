import AppKit
import RufCore
import ServiceManagement
import Sparkle

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let catalog = ApplicationCatalog()
    private let model = SwitcherModel()
    private let preferences = AppPreferences()

    private lazy var panelController = SwitcherPanelController(
        model: model,
        onChoose: { [weak self] index in
            self?.model.select(index)
            self?.commitSelection()
        }
    )

    private lazy var keyboardEventTap = KeyboardEventTap { [weak self] command in
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
    private var permissionMonitor: Timer?
    private var remainingPermissionChecks = 0
    private var snapshotTask: Task<Void, Never>?
    private var pendingActions: [SwitcherAction] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        enableLaunchAtLoginByDefaultIfNeeded()
        installStatusItem()
        panelController.prepare(itemCount: 0)
        applySwitcherMode()
        softwareUpdateController.startUpdater()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        if preferences.switcherMode == .ruf, !keyboardEventTap.isRunning {
            refreshShortcutState(
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
        stopPermissionMonitoring()
        keyboardEventTap.stop()
    }

    private func handle(_ command: SwitcherAction) {
        if snapshotTask != nil {
            if case .cancel = command {
                cancelSwitcher()
            } else {
                pendingActions.append(command)
            }
            return
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
        case .commit:
            commitSelection()
        case .cancel:
            cancelSwitcher()
        }
    }

    private func loadTargets(backwards: Bool) {
        pendingActions = []
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
        let actions = pendingActions
        pendingActions = []

        guard !targets.isEmpty else {
            keyboardEventTap.resetInputSession()
            return
        }

        model.begin(with: targets, backwards: backwards)

        for action in actions {
            handle(action)
            guard model.isPresented else {
                return
            }
        }

        panelController.show(itemCount: targets.count)
    }

    private func commitSelection() {
        keyboardEventTap.resetInputSession()
        let target = model.finish()
        panelController.hide()

        guard let target else {
            return
        }

        switch target.kind {
        case .application:
            target.item.application.activate(options: [.activateAllWindows])
        case let .window(window):
            ApplicationWindowService.activate(
                window,
                in: target.item.application
            )
        case .reopenApplication:
            ApplicationWindowService.reopen(target.item.application)
        }
    }

    private func cancelSwitcher() {
        snapshotTask?.cancel()
        snapshotTask = nil
        pendingActions = []
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
            withTitle: "Settings…",
            action: #selector(showSettings),
            keyEquivalent: ","
        ).target = self
        let softwareUpdateMenuItem = menu.addItem(
            withTitle: "Check for Updates…",
            action: #selector(
                SPUStandardUpdaterController.checkForUpdates(_:)
            ),
            keyEquivalent: ""
        )
        softwareUpdateMenuItem.target = softwareUpdateController
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
        if preferences.switcherMode == .system || keyboardEventTap.isRunning {
            accessibilityMenuItem?.isHidden = true
        } else {
            accessibilityMenuItem?.isHidden = false
            accessibilityMenuItem?.title = accessibilityGranted
                ? "Retry Ruf"
                : "Enable Accessibility…"
        }
    }

    private func refreshShortcutState(accessibilityGranted: Bool) {
        let shouldCaptureCommandTab = preferences.switcherMode == .ruf
            && accessibilityGranted

        if shouldCaptureCommandTab {
            stopPermissionMonitoring()
            keyboardEventTap.start()
        } else {
            keyboardEventTap.stop()

            if preferences.switcherMode == .system {
                stopPermissionMonitoring()
            }
        }

        updateAccessibilityMenuItem(accessibilityGranted: accessibilityGranted)
    }

    private func applySwitcherMode() {
        if preferences.switcherMode == .system, model.isPresented {
            cancelSwitcher()
        }

        let accessibilityGranted = AccessibilityPermission.isGranted
        refreshShortcutState(accessibilityGranted: accessibilityGranted)

        if preferences.switcherMode == .ruf,
           !accessibilityGranted {
            requestAccessibility(openSystemSettings: false)
        }
    }

    private func requestAccessibility(openSystemSettings: Bool) {
        guard preferences.switcherMode == .ruf else {
            return
        }

        AccessibilityPermission.request()

        if openSystemSettings {
            AccessibilityPermission.openSystemSettings()
        }

        startPermissionMonitoring()
    }

    private func startPermissionMonitoring() {
        let accessibilityGranted = AccessibilityPermission.isGranted
        if accessibilityGranted {
            refreshShortcutState(accessibilityGranted: accessibilityGranted)
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
            refreshShortcutState(accessibilityGranted: accessibilityGranted)
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
    private func showSettings() {
        settingsWindowController.show()
    }

    @objc
    private func enableAccessibility() {
        if preferences.switcherMode == .system {
            settingsWindowController.show()
        } else {
            let accessibilityGranted = AccessibilityPermission.isGranted
            if accessibilityGranted {
                refreshShortcutState(accessibilityGranted: accessibilityGranted)
            } else {
                requestAccessibility(openSystemSettings: true)
            }
        }
    }

    @objc
    private func quit() {
        NSApp.terminate(nil)
    }
}
