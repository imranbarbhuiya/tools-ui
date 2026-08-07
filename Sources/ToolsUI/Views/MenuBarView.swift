import AppKit
import SwiftUI

struct MenuBarView: View {
	@Bindable var store: ServiceStore
	@Binding var showManager: Bool
	@Environment(\.openWindow) private var openWindow

	var body: some View {
		if store.services.isEmpty {
			Text("No services yet")
		} else {
			ForEach(store.services) { service in
				let status = store.status(for: service.id)
				let mark = status.isRunning ? "●" : "○"
				Menu("\(mark)  \(service.name)") {
					if status.isRunning {
						Button("Stop") { store.stop(service.id) }
						Button("Restart") { store.restart(service.id) }
					} else {
						Button("Start") { store.start(service.id) }
					}
					if !service.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
						Button("Open URL") { store.openURL(service.id) }
					}
					if !service.workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
						Button("Open Folder") { store.openFolder(service.id) }
					}
					Divider()
					Text(status.label)
				}
			}
		}

		Divider()

		Button("Open Manager…") {
			openManager()
		}

		if store.anyRunning {
			Button("Stop All", role: .destructive) {
				store.stopAll()
			}
		}

		Divider()

		Button("Quit Tools UI") {
			store.stopAll()
			NSApp.terminate(nil)
		}
	}

	private func openManager() {
		openWindow(id: "manager")
		showManager = true
		NSApp.activate(ignoringOtherApps: true)
	}
}
