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
				Menu {
					if status.isRunning {
						Button("Stop", systemImage: "stop.fill") { store.stop(service.id) }
						Button("Restart", systemImage: "arrow.clockwise") { store.restart(service.id) }
					} else {
						Button("Start", systemImage: "play.fill") { store.start(service.id) }
					}
					if !service.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
						Button("Open URL", systemImage: "safari") { store.openURL(service.id) }
					}
					if !service.workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
						Button("Open Folder", systemImage: "folder") { store.openFolder(service.id) }
					}
					Divider()
					Text(status.label)
				} label: {
					Text("\(status.isRunning ? "●" : "○")  \(service.name)")
				}
			}
		}

		Divider()

		Button("Open Manager…", systemImage: "rectangle.split.2x1") {
			openManager()
		}
		.keyboardShortcut("m", modifiers: [.command])

		if store.anyRunning {
			Button("Stop All", systemImage: "stop.circle", role: .destructive) {
				store.stopAll()
			}
		}

		Divider()

		Button("Quit Tools UI", systemImage: "power") {
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
