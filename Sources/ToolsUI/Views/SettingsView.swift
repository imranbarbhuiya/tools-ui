import SwiftUI

struct SettingsView: View {
	@Bindable var store: ServiceStore

	var body: some View {
		Form {
			Section("About") {
				LabeledContent("Services", value: "\(store.services.count)")
				LabeledContent("Running", value: "\(store.statuses.values.filter(\.isRunning).count)")
				Text("Config: ~/Library/Application Support/ToolsUI/services.json")
					.font(.caption)
					.foregroundStyle(.secondary)
			}
			Section {
				Button("Stop all services", role: .destructive) {
					store.stopAll()
				}
			}
		}
		.formStyle(.grouped)
		.padding()
	}
}
