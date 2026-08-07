import SwiftUI

struct LogView: View {
	@Bindable var store: ServiceStore
	let serviceId: UUID
	@Environment(\.dismiss) private var dismiss

	var body: some View {
		let service = store.services.first(where: { $0.id == serviceId })
		let log = store.status(for: serviceId).log

		NavigationStack {
			ScrollView {
				Text(log.isEmpty ? "No output yet." : log)
					.font(.system(.callout, design: .monospaced))
					.foregroundStyle(log.isEmpty ? .tertiary : .primary)
					.frame(maxWidth: .infinity, alignment: .leading)
					.textSelection(.enabled)
					.padding(16)
			}
			.background(Color.primary.opacity(0.03))
			.navigationTitle(service.map { "\($0.name)" } ?? "Log")
			.toolbarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .cancellationAction) {
					Button("Done") { dismiss() }
						.keyboardShortcut(.cancelAction)
				}
				ToolbarItem(placement: .automatic) {
					Button("Clear") { store.clearLog(serviceId) }
						.disabled(log.isEmpty)
				}
			}
		}
		.frame(minWidth: 640, minHeight: 420)
	}
}
