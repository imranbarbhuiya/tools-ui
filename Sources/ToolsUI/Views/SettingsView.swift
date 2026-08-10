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
					Text("\(store.processServices.count) process · \(store.dockerServices.count) docker")
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
					if let availability = store.dockerAvailability {
						Label(
							availability.summary,
							systemImage: availability.isReady ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
						)
						.font(.caption.weight(.semibold))
						.foregroundStyle(availability.isReady ? .green : .orange)
					} else {
						Text("Checking…").foregroundStyle(.secondary)
					}
				}
				if let hint = store.dockerAvailability?.hint {
					Text(hint)
						.font(.caption)
						.foregroundStyle(.secondary)
				}
				LabeledContent("Containers") {
					Text("\(store.dockerContainers.count) known · \(store.unmanagedContainers.count) unmanaged")
						.foregroundStyle(.secondary)
				}
				Button("Re-scan Docker") {
					Task {
						store.dockerAvailability = nil
						await store.refreshDocker()
					}
				}
			} header: {
				Text("Docker")
			} footer: {
				Text("Containers are started and stopped with the docker CLI. Quitting Tools UI leaves them running.")
			}

			Section {
				LabeledContent("Status") {
					if let portless = store.portless {
						Label(
							portless.summary,
							systemImage: portless.isReady ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
						)
						.font(.caption.weight(.semibold))
						.foregroundStyle(portless.isReady ? .green : .orange)
					} else {
						Text("Checking…").foregroundStyle(.secondary)
					}
				}

				if let portless = store.portless {
					if let hint = portless.hint {
						Text(hint)
							.font(.caption)
							.foregroundStyle(.secondary)
						if !portless.isInstalled {
							Button("Install portless…") { Portless.openInTerminal(Portless.installCommand) }
						} else {
							Button("Start proxy now") {
								Task {
									await Portless.startProxy()
									await store.refreshPortless()
								}
							}
							.help("Starts on an unprivileged port without asking for a password")
							Button("Start proxy on 443 (sudo)…") {
								Portless.openInTerminal(Portless.proxyStartCommand)
							}
							Button("Start proxy at login…") {
								Portless.openInTerminal(Portless.serviceInstallCommand)
							}
						}
					}

					if !portless.routes.isEmpty {
						LabeledContent("Routes") {
							VStack(alignment: .trailing, spacing: 2) {
								ForEach(portless.routes.keys.sorted(), id: \.self) { host in
									Text(portless.routes[host] ?? host)
										.font(.caption2.monospaced())
										.foregroundStyle(.secondary)
										.textSelection(.enabled)
								}
							}
						}
					}
				}

				Button("Trust local CA…") { Portless.openInTerminal(Portless.trustCommand) }
				Button("Run doctor…") { Portless.openInTerminal(Portless.doctorCommand) }
				Button("Prune orphaned dev servers…") { Portless.openInTerminal(Portless.pruneCommand) }
				Button("Re-check") {
					Task { await store.refreshPortless() }
				}
			} header: {
				Text("Portless")
			} footer: {
				Text("Binding port 443 and trusting the local CA need a sudo prompt Tools UI cannot answer, so those run in Terminal.")
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
		.frame(width: 460)
		.task {
			await store.refreshAll()
		}
	}
}
