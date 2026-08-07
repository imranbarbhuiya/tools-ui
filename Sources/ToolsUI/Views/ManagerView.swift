import SwiftUI

struct ManagerView: View {
	@Bindable var store: ServiceStore
	@State private var selection: UUID?
	@State private var editor: EditorMode?
	@State private var showLogFor: UUID?

	enum EditorMode: Identifiable {
		case add
		case edit(ManagedService)

		var id: String {
			switch self {
			case .add: "add"
			case let .edit(s): s.id.uuidString
			}
		}
	}

	var body: some View {
		NavigationSplitView {
			VStack(spacing: 0) {
				List(selection: $selection) {
					ForEach(store.services) { service in
						ServiceRowView(service: service, status: store.status(for: service.id))
							.tag(service.id)
							.contextMenu {
								serviceMenu(service)
							}
					}
					.onMove(perform: store.move)
				}
				.listStyle(.sidebar)
				Divider()
				Button {
					editor = .add
				} label: {
					Label("Add Service", systemImage: "plus.circle.fill")
						.frame(maxWidth: .infinity, alignment: .leading)
				}
				.buttonStyle(.borderless)
				.padding(.horizontal, 12)
				.padding(.vertical, 10)
			}
			.navigationTitle("Services")
			.toolbar {
				ToolbarItemGroup {
					Button {
						editor = .add
					} label: {
						Label("Add", systemImage: "plus")
					}
					.help("Add Service")
					Button {
						store.stopAll()
					} label: {
						Label("Stop All", systemImage: "stop.circle")
					}
					.disabled(!store.anyRunning)
				}
			}
		} detail: {
			if let selection, let service = store.services.first(where: { $0.id == selection }) {
				ServiceDetailView(
					service: service,
					status: store.status(for: service.id),
					onStart: { store.start(service.id) },
					onStop: { store.stop(service.id) },
					onRestart: { store.restart(service.id) },
					onOpenURL: { store.openURL(service.id) },
					onOpenFolder: { store.openFolder(service.id) },
					onEdit: { editor = .edit(service) },
					onDelete: {
						store.delete(service.id)
						self.selection = nil
					},
					onShowLog: { showLogFor = service.id },
					onClearLog: { store.clearLog(service.id) }
				)
			} else {
				ContentUnavailableView(
					"Select a service",
					systemImage: "bolt.horizontal.circle",
					description: Text("Add local apps and toggle them from here or the menu bar.")
				)
			}
		}
		.sheet(item: $editor) { mode in
			switch mode {
			case .add:
				ServiceEditorView(title: "Add Service") { service in
					store.add(service)
					selection = service.id
				}
			case let .edit(existing):
				ServiceEditorView(title: "Edit Service", service: existing) { service in
					store.update(service)
				}
			}
		}
		.sheet(item: Binding(
			get: { showLogFor.map { LogSheetItem(id: $0) } },
			set: { showLogFor = $0?.id }
		)) { item in
			LogView(store: store, serviceId: item.id)
		}
		.overlay(alignment: .bottom) {
			if let err = store.lastError {
				Text(err)
					.font(.caption)
					.padding(.horizontal, 12)
					.padding(.vertical, 8)
					.background(.red.opacity(0.15), in: Capsule())
					.padding()
					.onTapGesture { store.lastError = nil }
			}
		}
	}

	@ViewBuilder
	private func serviceMenu(_ service: ManagedService) -> some View {
		let status = store.status(for: service.id)
		if status.isRunning {
			Button("Stop") { store.stop(service.id) }
			Button("Restart") { store.restart(service.id) }
		} else {
			Button("Start") { store.start(service.id) }
		}
		Button("Edit") { editor = .edit(service) }
		Button("Show Log") { showLogFor = service.id }
		Button("Delete", role: .destructive) {
			store.delete(service.id)
			if selection == service.id { selection = nil }
		}
	}
}

private struct LogSheetItem: Identifiable {
	let id: UUID
}

struct ServiceRowView: View {
	let service: ManagedService
	let status: ServiceStatus

	var body: some View {
		HStack(spacing: 10) {
			Circle()
				.fill(dotColor)
				.frame(width: 8, height: 8)
			VStack(alignment: .leading, spacing: 2) {
				Text(service.name)
					.font(.body.weight(.medium))
				Text(status.label)
					.font(.caption)
					.foregroundStyle(.secondary)
					.lineLimit(1)
			}
			Spacer(minLength: 0)
		}
		.padding(.vertical, 2)
	}

	private var dotColor: Color {
		switch status.state {
		case .running: .green
		case .starting: .yellow
		case .failed: .red
		case .stopped: .secondary
		}
	}
}

struct ServiceDetailView: View {
	let service: ManagedService
	let status: ServiceStatus
	var onStart: () -> Void
	var onStop: () -> Void
	var onRestart: () -> Void
	var onOpenURL: () -> Void
	var onOpenFolder: () -> Void
	var onEdit: () -> Void
	var onDelete: () -> Void
	var onShowLog: () -> Void
	var onClearLog: () -> Void

	var body: some View {
		ScrollView {
			VStack(alignment: .leading, spacing: 20) {
				HStack(alignment: .firstTextBaseline) {
					VStack(alignment: .leading, spacing: 6) {
						Text(service.name)
							.font(.largeTitle.weight(.semibold))
						Text(status.label)
							.foregroundStyle(.secondary)
					}
					Spacer()
					statusBadge
				}

				HStack(spacing: 10) {
					if status.isRunning {
						Button("Stop", role: .destructive, action: onStop)
							.buttonStyle(.borderedProminent)
							.tint(.red)
						Button("Restart", action: onRestart)
							.buttonStyle(.bordered)
					} else {
						Button("Start", action: onStart)
							.buttonStyle(.borderedProminent)
					}
					if !service.url.isEmpty {
						Button("Open URL", action: onOpenURL)
							.buttonStyle(.bordered)
					}
					if !service.workingDirectory.isEmpty {
						Button("Folder", action: onOpenFolder)
							.buttonStyle(.bordered)
					}
					Button("Log", action: onShowLog)
						.buttonStyle(.bordered)
					Spacer()
					Button("Edit", action: onEdit)
					Button("Delete", role: .destructive, action: onDelete)
				}

				GroupBox("Command") {
					VStack(alignment: .leading, spacing: 8) {
						labeled("Working dir", service.workingDirectory.isEmpty ? "—" : service.workingDirectory)
						labeled("Command", service.command)
						labeled("URL", service.url.isEmpty ? "—" : service.url)
						labeled("PID", status.pidText)
						labeled("Auto-start", service.autoStart ? "Yes" : "No")
						if !service.notes.isEmpty {
							labeled("Notes", service.notes)
						}
					}
					.frame(maxWidth: .infinity, alignment: .leading)
					.padding(4)
				}

				GroupBox("Live log") {
					ScrollView {
						Text(status.log.isEmpty ? "No output yet." : status.log)
							.font(.system(.caption, design: .monospaced))
							.frame(maxWidth: .infinity, alignment: .leading)
							.textSelection(.enabled)
					}
					.frame(minHeight: 160, maxHeight: 280)
					.padding(4)
					HStack {
						Spacer()
						Button("Clear", action: onClearLog)
							.controlSize(.small)
					}
				}
			}
			.padding(24)
		}
		.background(Color(nsColor: .windowBackgroundColor))
	}

	private var statusBadge: some View {
		Text(status.isRunning ? "ON" : "OFF")
			.font(.caption.weight(.bold))
			.padding(.horizontal, 10)
			.padding(.vertical, 4)
			.background(status.isRunning ? Color.green.opacity(0.2) : Color.secondary.opacity(0.15), in: Capsule())
	}

	private func labeled(_ title: String, _ value: String) -> some View {
		HStack(alignment: .top) {
			Text(title)
				.foregroundStyle(.secondary)
				.frame(width: 100, alignment: .leading)
			Text(value)
				.font(.body.monospaced())
				.textSelection(.enabled)
			Spacer(minLength: 0)
		}
	}
}
