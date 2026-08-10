import SwiftUI

struct SettingsView: View {
	@Bindable var store: ServiceStore

	var body: some View {
		Form {
			Section {
				HStack {
					Spacer()
					AppLogoView(size: 72)
					Spacer()
				}
				.listRowBackground(Color.clear)
				LabeledContent("Services") {
					Text("\(store.services.count)")
						.foregroundStyle(.secondary)
				}
				LabeledContent("Running") {
					Text("\(store.statuses.values.filter(\.isRunning).count)")
						.foregroundStyle(.secondary)
				}
			} header: {
				Text("Overview")
			}

			Section {
				LabeledContent("Status") {
					if let health = store.portlessHealth {
						Label(health.summary, systemImage: health.isReady ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
							.font(.caption.weight(.semibold))
							.foregroundStyle(health.isReady ? .green : .orange)
					} else {
						Text("Checking…")
							.foregroundStyle(.secondary)
					}
				}

				if let health = store.portlessHealth, let hint = health.hint {
					Text(hint)
						.font(.caption)
						.foregroundStyle(.secondary)
					if !health.isInstalled {
						Button("Install portless…") { Portless.openInTerminal(Portless.installCommand) }
					} else {
						Button("Start proxy at login…") { Portless.openInTerminal(Portless.serviceInstallCommand) }
					}
				}

				Button("Trust local CA…") { Portless.openInTerminal(Portless.trustCommand) }
				Button("Run doctor…") { Portless.openInTerminal(Portless.doctorCommand) }
				Button("Prune orphaned dev servers…") { Portless.openInTerminal(Portless.pruneCommand) }
				Button("Re-check") {
					Task { await store.refreshPortlessHealth() }
				}
			} header: {
				Text("Portless")
			} footer: {
				Text("Setup runs in Terminal because binding port 443 and trusting the local CA need a sudo prompt Tools UI cannot answer.")
			}

			Section {
				LabeledContent("Config file") {
					Text("~/Library/Application Support/ToolsUI/services.json")
						.font(.caption.monospaced())
						.foregroundStyle(.secondary)
						.textSelection(.enabled)
				}
			} header: {
				Text("Storage")
			} footer: {
				Text("Services and options are stored as JSON on this Mac only.")
			}

			Section {
				Button("Stop all services", role: .destructive) {
					store.stopAll()
				}
				.disabled(!store.anyRunning)
			}
		}
		.formStyle(.grouped)
		.padding()
		.frame(width: 440)
		.task {
			await store.refreshPortlessHealth()
		}
	}
}
