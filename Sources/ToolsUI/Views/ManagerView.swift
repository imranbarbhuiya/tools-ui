import SwiftUI

struct ManagerView: View {
	@Bindable var store: ServiceStore
	@State private var selection: UUID?
	@State private var editor: EditorMode?
	@State private var showLogFor: UUID?
	@State private var search = ""

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

	private var filtered: [ManagedService] {
		let q = search.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !q.isEmpty else { return store.services }
		return store.services.filter {
			$0.name.localizedCaseInsensitiveContains(q)
				|| $0.command.localizedCaseInsensitiveContains(q)
				|| $0.workingDirectory.localizedCaseInsensitiveContains(q)
		}
	}

	var body: some View {
		NavigationSplitView {
			sidebar
		} detail: {
			detail
		}
		.navigationSplitViewStyle(.balanced)
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
				errorToast(err)
			}
		}
	}

	private var sidebar: some View {
		VStack(spacing: 0) {
			List(selection: $selection) {
				Section {
					if filtered.isEmpty {
						ContentUnavailableView {
							Label(
								store.services.isEmpty ? "No services" : "No matches",
								systemImage: store.services.isEmpty ? "shippingbox" : "magnifyingglass"
							)
						} description: {
							Text(store.services.isEmpty
								? "Add a local command to start, stop, and open it from the menu bar."
								: "Try another search.")
						}
						.frame(maxWidth: .infinity)
						.padding(.vertical, 24)
						.listRowBackground(Color.clear)
						.listRowSeparator(.hidden)
					} else {
						ForEach(filtered) { service in
							ServiceRowView(service: service, status: store.status(for: service.id))
								.tag(service.id)
								.contextMenu { serviceMenu(service) }
						}
						.onMove(perform: store.move)
					}
				} header: {
					HStack {
						Text("Services")
						Spacer()
						Text("\(store.statuses.values.filter(\.isRunning).count) running")
							.font(.caption2.weight(.medium))
							.foregroundStyle(.tertiary)
					}
				}
			}
			.listStyle(.sidebar)
			.searchable(text: $search, placement: .sidebar, prompt: "Filter")

			sidebarFooter
		}
		.navigationSplitViewColumnWidth(min: Theme.sidebarMin, ideal: Theme.sidebarIdeal, max: 320)
		.toolbar {
			ToolbarItemGroup(placement: .primaryAction) {
				Button {
					editor = .add
				} label: {
					Label("Add", systemImage: "plus")
				}
				.help("Add Service")
				.keyboardShortcut("n", modifiers: [.command])

				Button {
					store.stopAll()
				} label: {
					Label("Stop All", systemImage: "stop.fill")
				}
				.disabled(!store.anyRunning)
				.help("Stop all running services")
			}
		}
	}

	private var sidebarFooter: some View {
		VStack(spacing: 0) {
			Divider()
			Button {
				editor = .add
			} label: {
				Label("Add Service", systemImage: "plus")
					.font(.body.weight(.medium))
					.frame(maxWidth: .infinity)
					.padding(.vertical, 9)
			}
			.buttonStyle(.bordered)
			.controlSize(.regular)
			.padding(.horizontal, 12)
			.padding(.vertical, 10)
			.background(.bar)
		}
	}

	@ViewBuilder
	private var detail: some View {
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
			.id(service.id)
			.transition(.opacity.combined(with: .move(edge: .trailing)))
		} else {
			ContentUnavailableView {
				VStack(spacing: 14) {
					AppLogoView(size: 84)
					Text("Tools UI")
						.font(.system(.title, design: .rounded).weight(.semibold))
				}
			} description: {
				Text("Select a service, or add one to manage local processes like a dock for CLIs.")
			} actions: {
				Button("Add Service") { editor = .add }
					.buttonStyle(.borderedProminent)
			}
			.frame(maxWidth: .infinity, maxHeight: .infinity)
			.background()
		}
	}

	private func errorToast(_ err: String) -> some View {
		HStack(spacing: 10) {
			Image(systemName: "exclamationmark.triangle.fill")
				.foregroundStyle(.orange)
			Text(err)
				.font(.callout)
				.lineLimit(2)
			Spacer(minLength: 8)
			Button {
				store.lastError = nil
			} label: {
				Image(systemName: "xmark.circle.fill")
					.symbolRenderingMode(.hierarchical)
					.foregroundStyle(.secondary)
			}
			.buttonStyle(.plain)
		}
		.padding(.horizontal, 14)
		.padding(.vertical, 10)
		.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
		.shadow(color: .black.opacity(0.18), radius: 16, y: 6)
		.padding(16)
		.transition(.move(edge: .bottom).combined(with: .opacity))
	}

	@ViewBuilder
	private func serviceMenu(_ service: ManagedService) -> some View {
		let status = store.status(for: service.id)
		if status.isRunning {
			Button("Stop", systemImage: "stop.fill") { store.stop(service.id) }
			Button("Restart", systemImage: "arrow.clockwise") { store.restart(service.id) }
		} else {
			Button("Start", systemImage: "play.fill") { store.start(service.id) }
		}
		Divider()
		Button("Edit", systemImage: "pencil") { editor = .edit(service) }
		Button("Show Log", systemImage: "text.alignleft") { showLogFor = service.id }
		Divider()
		Button("Delete", systemImage: "trash", role: .destructive) {
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
		HStack(spacing: 12) {
			ServiceAvatar(name: service.name, isRunning: status.isRunning, size: 32)
			VStack(alignment: .leading, spacing: 2) {
				Text(service.name)
					.font(.body.weight(.medium))
					.lineLimit(1)
				Text(status.label)
					.font(.caption)
					.foregroundStyle(status.state.tint.opacity(0.9))
					.lineLimit(1)
			}
			Spacer(minLength: 0)
			Circle()
				.fill(status.state.tint)
				.frame(width: 7, height: 7)
				.opacity({
					switch status.state {
					case .running, .starting, .failed: 1
					case .stopped: 0.35
					}
				}())
		}
		.padding(.vertical, 4)
		.accessibilityElement(children: .combine)
		.accessibilityLabel("\(service.name), \(status.label)")
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
			VStack(alignment: .leading, spacing: 22) {
				header
				actionBar
				detailsCard
				logCard
			}
			.frame(maxWidth: Theme.contentMax, alignment: .leading)
			.frame(maxWidth: .infinity, alignment: .leading)
			.padding(28)
		}
		.background()
		.toolbar {
			ToolbarItemGroup(placement: .primaryAction) {
				if status.isRunning {
					Button(action: onRestart) {
						Label("Restart", systemImage: "arrow.clockwise")
					}
					Button(role: .destructive, action: onStop) {
						Label("Stop", systemImage: "stop.fill")
					}
				} else {
					Button(action: onStart) {
						Label("Start", systemImage: "play.fill")
					}
					.keyboardShortcut(.return, modifiers: [.command])
				}
			}
			ToolbarItem(placement: .automatic) {
				Menu {
					if !service.url.isEmpty {
						Button("Open URL", systemImage: "safari") { onOpenURL() }
					}
					if !service.workingDirectory.isEmpty {
						Button("Reveal in Finder", systemImage: "folder") { onOpenFolder() }
					}
					Button("Full Log…", systemImage: "doc.plaintext") { onShowLog() }
					Divider()
					Button("Edit…", systemImage: "pencil") { onEdit() }
					Button("Delete…", systemImage: "trash", role: .destructive) { onDelete() }
				} label: {
					Label("More", systemImage: "ellipsis.circle")
				}
			}
		}
	}

	private var header: some View {
		HStack(alignment: .center, spacing: 16) {
			ServiceAvatar(name: service.name, isRunning: status.isRunning, size: 56)
			VStack(alignment: .leading, spacing: 6) {
				Text(service.name)
					.font(.system(.largeTitle, design: .rounded).weight(.semibold))
				HStack(spacing: 8) {
					StatusChip(state: status.state)
					if case let .running(pid) = status.state {
						Text("PID \(pid)")
							.font(.caption.monospaced())
							.foregroundStyle(.tertiary)
					}
					if let started = status.startedAt, status.isRunning {
						Text("\(started, style: .relative) ago")
							.font(.caption)
							.foregroundStyle(.tertiary)
					}
				}
				if !service.notes.isEmpty {
					Text(service.notes)
						.font(.subheadline)
						.foregroundStyle(.secondary)
						.lineLimit(2)
				}
			}
			Spacer(minLength: 0)
		}
	}

	private var actionBar: some View {
		HStack(spacing: 10) {
			if status.isRunning {
				Button(action: onStop) {
					Label("Stop", systemImage: "stop.fill")
						.frame(minWidth: 88)
				}
				.buttonStyle(.borderedProminent)
				.tint(.red)
				.controlSize(.large)

				Button(action: onRestart) {
					Label("Restart", systemImage: "arrow.clockwise")
				}
				.buttonStyle(.bordered)
				.controlSize(.large)
			} else {
				Button(action: onStart) {
					Label("Start", systemImage: "play.fill")
						.frame(minWidth: 88)
				}
				.buttonStyle(.borderedProminent)
				.controlSize(.large)
			}

			if !service.url.isEmpty {
				Button(action: onOpenURL) {
					Label("Open", systemImage: "safari")
				}
				.buttonStyle(.bordered)
				.controlSize(.large)
			}

			if !service.workingDirectory.isEmpty {
				Button(action: onOpenFolder) {
					Label("Folder", systemImage: "folder")
				}
				.buttonStyle(.bordered)
				.controlSize(.large)
			}

			Spacer(minLength: 0)
		}
	}

	private var detailsCard: some View {
		InsetCard(title: "Configuration") {
			VStack(spacing: 0) {
				MetaRow(title: "Command", value: service.command, mono: true)
				Divider().padding(.leading, 108)
				MetaRow(
					title: "Directory",
					value: service.workingDirectory.isEmpty ? "—" : service.workingDirectory,
					mono: true
				)
				Divider().padding(.leading, 108)
				MetaRow(title: "URL", value: service.url.isEmpty ? "—" : service.url, mono: true)
				Divider().padding(.leading, 108)
				MetaRow(title: "Auto-start", value: service.autoStart ? "On launch" : "Manual")
			}
		}
	}

	private var logCard: some View {
		InsetCard(title: "Output") {
			VStack(alignment: .leading, spacing: 10) {
				ScrollView {
					Text(status.log.isEmpty ? "No output yet. Start the service to stream logs here." : status.log)
						.font(.system(.caption, design: .monospaced))
						.foregroundStyle(status.log.isEmpty ? .tertiary : .primary)
						.frame(maxWidth: .infinity, alignment: .leading)
						.textSelection(.enabled)
				}
				.frame(minHeight: 180, maxHeight: 300)
				.padding(10)
				.background {
					RoundedRectangle(cornerRadius: 8, style: .continuous)
						.fill(Color.primary.opacity(0.04))
				}

				HStack {
					Button("Full log", systemImage: "arrow.up.left.and.arrow.down.right", action: onShowLog)
						.controlSize(.small)
					Spacer()
					Button("Clear", systemImage: "trash", action: onClearLog)
						.controlSize(.small)
						.disabled(status.log.isEmpty)
				}
			}
		}
	}
}
