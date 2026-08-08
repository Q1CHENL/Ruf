import AppKit
import RufCore
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @Bindable var preferences: AppPreferences
    let onKeyboardCaptureChanged: () -> Void

    var body: some View {
        Form {
            Section("General") {
                Picker("Command-Tab", selection: $preferences.switcherMode) {
                    Text("Ruf")
                        .tag(AppSwitcherMode.ruf)
                    Text("macOS")
                        .tag(AppSwitcherMode.system)
                }
                .pickerStyle(.radioGroup)

                LaunchAtLoginSetting(
                    onUserChange: preferences.markLaunchAtLoginConfigured
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
                        "Open new window for selected app",
                        keys: "⌘N"
                    )
                    ShortcutRow(
                        "Quit selected app",
                        keys: "⌘Q"
                    )
                }
                .opacity(preferences.switcherMode == .ruf ? 1 : 0.45)

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
            } header: {
                Text("Keyboard Shortcuts")
            } footer: {
                if preferences.switcherMode == .ruf {
                    Text(
                        "New Window and Quit act on the selected app after "
                            + "all shortcut keys are released."
                    )
                } else {
                    Text(
                        "Switcher navigation, New Window, and Quit require "
                            + "Command-Tab to use Ruf."
                    )
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 440)
        .onChange(of: preferences.switcherMode) {
            onKeyboardCaptureChanged()
        }
        .onChange(of: preferences.isWindowMovementEnabled) {
            onKeyboardCaptureChanged()
        }
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
