import RufCore
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
        }
        .formStyle(.grouped)
        .frame(width: 440, height: 140)
        .onChange(of: preferences.switcherMode) {
            onSwitcherModeChanged()
        }
    }
}
