import AppKit
import RufCore

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

    private lazy var softwareUpdateController = SoftwareUpdateController {
        [weak self] _ in
        self?.updateSoftwareUpdateMenuItem()
    }

    private var statusItem: NSStatusItem?
    private var softwareUpdateMenuItem: NSMenuItem?
    private var accessibilityMenuItem: NSMenuItem?
    private var permissionMonitor: Timer?
    private var remainingPermissionChecks = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        installStatusItem()
        let initialApplications = catalog.snapshot()
        panelController.prepare(itemCount: initialApplications.count)
        applySwitcherMode()
        softwareUpdateController.start()
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
        stopPermissionMonitoring()
        keyboardEventTap.stop()
    }

    private func handle(_ command: SwitcherAction) {
        switch command {
        case let .cycle(backwards):
            if model.isPresented {
                model.move(backwards ? .backward : .forward)
            } else {
                let applications = catalog.snapshot()
                model.begin(with: applications, backwards: backwards)

                if model.isPresented {
                    panelController.show(itemCount: applications.count)
                }
            }
        case let .move(move):
            model.move(move)
        case .commit:
            commitSelection()
        case .cancel:
            cancelSwitcher()
        }
    }

    private func commitSelection() {
        keyboardEventTap.resetInputSession()
        let application = model.finish()
        panelController.hide()
        application?.activate(options: [.activateAllWindows])
    }

    private func cancelSwitcher() {
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
        menu.delegate = self
        menu.addItem(
            withTitle: "Settings…",
            action: #selector(showSettings),
            keyEquivalent: ","
        ).target = self
        let softwareUpdateMenuItem = menu.addItem(
            withTitle: "Check for Updates…",
            action: #selector(performSoftwareUpdateAction),
            keyEquivalent: ""
        )
        softwareUpdateMenuItem.target = self
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
        let accessibilityGranted = preferences.switcherMode == .ruf
            && !keyboardEventTap.isRunning
            && AccessibilityPermission.isGranted
        updateAccessibilityMenuItem(accessibilityGranted: accessibilityGranted)
    }

    private func updateSoftwareUpdateMenuItem() {
        let title = switch softwareUpdateController.state {
        case .idle:
            "Check for Updates…"
        case .checking:
            "Checking for Updates…"
        case let .available(version):
            "Download Ruf \(version)…"
        case let .downloading(version):
            "Downloading Ruf \(version)…"
        case .readyToInstall:
            "Restart Ruf to Update"
        case let .installing(version):
            "Installing Ruf \(version)…"
        }

        softwareUpdateMenuItem?.title = title
        softwareUpdateMenuItem?.isEnabled =
            softwareUpdateController.canPerformPrimaryAction
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

    @objc
    private func showSettings() {
        settingsWindowController.show()
    }

    @objc
    private func performSoftwareUpdateAction() {
        softwareUpdateController.performPrimaryAction()
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
