import AppKit
import RufCore
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @Bindable var preferences: AppPreferences
    let softwareUpdateAvailability: SoftwareUpdateAvailability
    let onPreferencesChanged: () -> Void
    let onShowAbout: () -> Void
    let onCheckForUpdates: () -> Void
    let onOpenAccessibilitySettings: () -> Void
    let onQuit: () -> Void

    var body: some View {
        Form {
            Section {
                Picker("Command-Tab", selection: $preferences.switcherMode) {
                    Text("Ruf")
                        .tag(AppSwitcherMode.ruf)
                    Text("macOS")
                        .tag(AppSwitcherMode.system)
                }
                .pickerStyle(.radioGroup)

                Toggle(
                    "Show Ruf in Menu Bar",
                    isOn: $preferences.showsMenuBarItem
                )
                .disabled(preferences.switcherMode != .ruf)

                Toggle(
                    "Show App Resource Usage",
                    isOn: $preferences.showsApplicationResourceUsage
                )

                LaunchAtLoginSetting(
                    onUserChange: preferences.markLaunchAtLoginConfigured
                )
            } header: {
                Text("General")
            } footer: {
                Text(
                    "When hidden, select Ruf in the switcher to reopen "
                        + "Settings. macOS mode keeps the menu bar item visible."
                )
            }

            Section {
                ShortcutRow(
                    "Switch applications",
                    keys: "⌘Tab / ⇧⌘Tab"
                )

                Group {
                    ShortcutRow(
                        "Navigate selection",
                        keys: "⌘ + ← ↑ ↓ →"
                    )
                    ShortcutRow(
                        "Toggle app resource usage",
                        keys: "⌘I"
                    )
                    ConfigurableShortcutRow(
                        "Jump to first / last",
                        keys: "⌘Page Up / ⌘Page Down",
                        isOn: $preferences.isJumpToFirstOrLastEnabled
                    )
                    ConfigurableShortcutRow(
                        "Open new window for selected app",
                        keys: "⌘N",
                        isOn: $preferences.isNewWindowShortcutEnabled
                    )
                    ConfigurableShortcutRow(
                        "Quit selected app",
                        keys: "⌘Q",
                        isOn: $preferences.isQuitShortcutEnabled
                    )
                }
                .opacity(preferences.switcherMode == .ruf ? 1 : 0.45)
                .disabled(preferences.switcherMode != .ruf)

                LabeledContent("Move current window between displays") {
                    HStack(spacing: 12) {
                        Text("⌃⌥⌘ + ← ↑ ↓ →")
                            .foregroundStyle(.secondary)
                            .lineLimit(1)

                        Toggle(
                            "Move current window between displays",
                            isOn: $preferences.isWindowMovementEnabled
                        )
                        .toggleStyle(.switch)
                        .labelsHidden()
                    }
                }

                Picker(
                    "Movement style",
                    selection: $preferences.windowMovementStyle
                ) {
                    Text("Continuous")
                        .tag(WindowMovementStyle.live)
                    Text("Ghost")
                        .tag(WindowMovementStyle.outline)
                }
                .pickerStyle(.radioGroup)
                .disabled(!preferences.isWindowMovementEnabled)
            } header: {
                Text("Keyboard Shortcuts")
            } footer: {
                if preferences.switcherMode == .ruf {
                    Text(
                        "Enabled app actions run after "
                            + "all shortcut keys are released."
                    )
                } else {
                    Text(
                        "Switcher navigation, New Window, and Quit require "
                            + "Command-Tab to use Ruf."
                    )
                }
            }

            Section("Ruf") {
                AccessibilitySetting(
                    isRequired: preferences.requiresAccessibilityPermission,
                    onOpenSystemSettings: onOpenAccessibilitySettings
                )

                HStack(spacing: 12) {
                    SettingsActionButton(
                        "About Ruf…",
                        action: onShowAbout
                    )
                    SettingsActionButton(
                        softwareUpdateAvailability.actionTitle,
                        action: onCheckForUpdates
                    )
                    SettingsActionButton("Quit Ruf", action: onQuit)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: preferences.switcherMode) {
            onPreferencesChanged()
        }
        .onChange(of: preferences.showsMenuBarItem) {
            onPreferencesChanged()
        }
        .onChange(of: preferences.isWindowMovementEnabled) {
            onPreferencesChanged()
        }
        .onChange(of: preferences.enabledSwitcherShortcuts) {
            onPreferencesChanged()
        }
    }
}

private struct SettingsActionButton: View {
    let title: String
    let action: () -> Void

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
    }
}

private struct ShortcutRow: View {
    let title: String
    let keys: String

    init(_ title: String, keys: String) {
        self.title = title
        self.keys = keys
    }

    var body: some View {
        LabeledContent(title) {
            Text(keys)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

private struct ConfigurableShortcutRow: View {
    let title: String
    let keys: String
    @Binding var isOn: Bool

    init(_ title: String, keys: String, isOn: Binding<Bool>) {
        self.title = title
        self.keys = keys
        _isOn = isOn
    }

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 12) {
                Text(keys)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Toggle(title, isOn: $isOn)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
        }
    }
}

private struct LaunchAtLoginSetting: View {
    let onUserChange: () -> Void

    @State private var status = SMAppService.mainApp.status
    @State private var errorMessage: String?

    var body: some View {
        Toggle("Launch at Login", isOn: registrationBinding)
            .onAppear(perform: refreshStatus)
            .onReceive(
                NotificationCenter.default.publisher(
                    for: NSApplication.didBecomeActiveNotification
                )
            ) { _ in
                refreshStatus()
            }
            .alert(
                "Ruf Couldn’t Change Launch at Login",
                isPresented: errorPresentation
            ) {
                Button("OK", role: .cancel) {
                    errorMessage = nil
                }
            } message: {
                Text(errorMessage ?? "")
            }

        if status == .requiresApproval {
            HStack {
                Text("Approval is required in System Settings.")
                    .foregroundStyle(.secondary)

                Spacer()

                Button("Open Login Items…") {
                    SMAppService.openSystemSettingsLoginItems()
                }
            }
        }
    }

    private var registrationBinding: Binding<Bool> {
        Binding(
            get: { isRegistered },
            set: { shouldRegister in
                updateRegistration(shouldRegister)
            }
        )
    }

    private var errorPresentation: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { isPresented in
                if !isPresented {
                    errorMessage = nil
                }
            }
        )
    }

    private var isRegistered: Bool {
        status == .enabled || status == .requiresApproval
    }

    private func updateRegistration(_ shouldRegister: Bool) {
        onUserChange()

        do {
            if shouldRegister {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            refreshStatus()

            if isRegistered != shouldRegister {
                errorMessage = error.localizedDescription
            }

            return
        }

        refreshStatus()
    }

    private func refreshStatus() {
        status = SMAppService.mainApp.status
    }
}

private struct AccessibilitySetting: View {
    let isRequired: Bool
    let onOpenSystemSettings: () -> Void

    @State private var isGranted = AccessibilityPermission.isGranted

    var body: some View {
        LabeledContent("Accessibility") {
            HStack(spacing: 12) {
                Text(statusLabel)
                    .foregroundStyle(.secondary)

                Button("Open System Settings…") {
                    onOpenSystemSettings()
                }
                .buttonStyle(.bordered)
            }
        }
        .onAppear(perform: refreshStatus)
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSApplication.didBecomeActiveNotification
            )
        ) { _ in
            refreshStatus()
        }
    }

    private var statusLabel: String {
        if isGranted {
            return "Enabled"
        }

        return isRequired ? "Required" : "Not Enabled"
    }

    private func refreshStatus() {
        isGranted = AccessibilityPermission.isGranted
    }
}
