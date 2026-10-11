import SwiftUI

struct LogView: View {
	@Bindable var store: ServiceStore
	let serviceId: UUID
	@Environment(\.dismiss) private var dismiss

	var body: some View {
		NavigationStack {
			LogTimelineView(store: store, serviceID: serviceId)
				.navigationTitle(store.find(serviceId)?.name ?? "Log")
				.toolbarTitleDisplayMode(.inline)
				.toolbar {
					ToolbarItem(placement: .cancellationAction) {
						Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
					}
				}
		}.frame(minWidth: 760, minHeight: 500)
	}
}

struct LogsWindow: View {
	@Bindable var store: ServiceStore
	var body: some View {
		LogTimelineView(store: store)
			.frame(minWidth: 760, minHeight: 500)
			.task {
				while !Task.isCancelled {
					await store.refreshRuntime()
					try? await Task.sleep(for: .seconds(4))
				}
			}
	}
}
