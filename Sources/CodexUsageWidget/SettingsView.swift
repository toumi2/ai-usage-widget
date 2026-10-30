import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @ObservedObject var controller: UsageController

    var body: some View {
        Form {
            Section("Service") {
                Picker("Show", selection: Binding(
                    get: { controller.providerMode },
                    set: controller.setProviderMode
                )) {
                    ForEach(ProviderMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.menu)

                Text("Auto shows Claude when the Claude app is in front and Codex when the Codex app is. Other apps keep the last one shown.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

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
                    Text("Allow AI Usage in System Settings → General → Login Items.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Sources") {
                HStack {
                    Text("Codex")
                    Spacer()
                    Text("Signed-in Codex CLI")
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text("Claude")
                    Spacer()
                    Text("Signed-in Claude Code CLI (/usage)")
                        .foregroundStyle(.secondary)
                }
                Button("Refresh \(controller.provider.label) usage now") { controller.refresh() }
                    .disabled(controller.isRefreshing)
            }
        }
        .formStyle(.grouped)
        .frame(width: 360)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.top, 8)
    }
}
