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
			section(title: "Services", services: store.processServices)
			section(title: "Docker", services: store.dockerServices)
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
			store.shutdown()
			NSApp.terminate(nil)
		}
	}

	@ViewBuilder
	private func section(title: String, services: [ManagedService]) -> some View {
		if !services.isEmpty {
			Section(title) {
				ForEach(services) { service in
					let status = store.status(for: service.id)
					Menu {
						if status.isRunning {
							Button("Stop", systemImage: "stop.fill") { store.stop(service.id) }
							Button("Restart", systemImage: "arrow.clockwise") { store.restart(service.id) }
						} else {
							Button(startLabel(for: service), systemImage: "play.fill") { store.start(service.id) }
						}
						if !store.effectiveURL(for: service).isEmpty {
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
		}
	}

	private func startLabel(for service: ManagedService) -> String {
		let count = service.dependencies.count
		return count == 0 ? "Start" : "Start (with \(count) dependencies)"
	}

	private func openManager() {
		openWindow(id: "manager")
		showManager = true
		NSApp.activate(ignoringOtherApps: true)
	}
}
