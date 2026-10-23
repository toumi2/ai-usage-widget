import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @ObservedObject var controller: UsageController

    var body: some View {
        Form {
            Section("Widget") {
                Picker("Size", selection: Binding(
                    get: { controller.size },
                    set: controller.setSize
                )) {
                    ForEach(WidgetSize.allCases) { size in
                        Text(size.label).tag(size)
                    }
                }
                .pickerStyle(.menu)

                Picker("Background", selection: Binding(
                    get: { controller.backgroundMode },
                    set: controller.setBackgroundMode
                )) {
                    ForEach(WidgetBackgroundMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.menu)

                Text("Choose when the glass panel appears.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Updates") {
                Picker("Refresh every", selection: Binding(
                    get: { controller.refreshInterval },
                    set: controller.setRefreshInterval
                )) {
                    ForEach(RefreshInterval.allCases) { interval in
                        Text(interval.label).tag(interval)
                    }
                }
                .pickerStyle(.menu)

                Text("Also refreshes when you return to a reading older than the selected interval. Use the refresh button anytime.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Startup") {
                Toggle("Open at login", isOn: Binding(
                    get: { controller.startupEnabled },
                    set: controller.setStartupEnabled
                ))
                .disabled(SMAppService.mainApp.status == .requiresApproval)

                if SMAppService.mainApp.status == .requiresApproval {
                    Text("Allow Codex Usage in System Settings → General → Login Items.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Codex") {
                HStack {
                    Text("Usage source")
                    Spacer()
                    Text("Signed-in Codex CLI")
                        .foregroundStyle(.secondary)
                }
                Button("Refresh usage now") { controller.refresh() }
                    .disabled(controller.isRefreshing)
            }
        }
        .formStyle(.grouped)
        .frame(width: 360)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.top, 8)
    }
}
