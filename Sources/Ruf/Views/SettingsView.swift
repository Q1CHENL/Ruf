import AppKit
import RufCore
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @Bindable var preferences: AppPreferences
    let onSwitcherModeChanged: () -> Void

    var body: some View {
        Form {
            Section {
                Picker(selection: $preferences.switcherMode) {
                    Text("Ruf")
                        .tag(AppSwitcherMode.ruf)
                    Text("macOS")
                        .tag(AppSwitcherMode.system)
                } label: {
                    HStack(spacing: 0) {
                        Image(systemName: "command")
                        Image(systemName: "arrow.right.to.line.compact")
                    }
                    .accessibilityLabel("Command-Tab")
                }
                .pickerStyle(.radioGroup)
            }

            Section {
                LabeledContent("Move current window") {
                    Text("⌃⌥⌘ + ← ↑ ↓ →")
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                LaunchAtLoginSetting(
                    onUserChange: preferences.markLaunchAtLoginConfigured
                )
            }
        }
        .formStyle(.grouped)
        .frame(width: 440, height: 240)
        .onChange(of: preferences.switcherMode) {
            onSwitcherModeChanged()
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
