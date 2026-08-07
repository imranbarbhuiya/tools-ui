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
	}
}
