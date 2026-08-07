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
					.font(.system(.body, design: .monospaced))
					.frame(maxWidth: .infinity, alignment: .leading)
					.textSelection(.enabled)
					.padding()
			}
			.navigationTitle(service.map { "\($0.name) log" } ?? "Log")
			.toolbar {
				ToolbarItem(placement: .cancellationAction) {
					Button("Close") { dismiss() }
				}
				ToolbarItem(placement: .automatic) {
					Button("Clear") { store.clearLog(serviceId) }
				}
			}
		}
		.frame(minWidth: 560, minHeight: 360)
	}
}
