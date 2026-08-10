import AppKit
import SwiftUI

struct ManagerView: View {
	@Bindable var store: ServiceStore
	@State private var selection: UUID?
	@State private var editor: EditorMode?
	@State private var sheet: SheetMode?
	@State private var showLogFor: UUID?
	@State private var search = ""

	enum EditorMode: Identifiable {
		case add
		case edit(ManagedService)

		var id: String {
			switch self {
			case .add: "add"
			case let .edit(service): service.id.uuidString
			}
		}
	}

	enum SheetMode: String, Identifiable {
		case catalog
		case folder
		case compose

		var id: String { rawValue }
	}

	private func matches(_ service: ManagedService) -> Bool {
		let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !query.isEmpty else { return true }
		return service.name.localizedCaseInsensitiveContains(query)
			|| service.command.localizedCaseInsensitiveContains(query)
			|| service.workingDirectory.localizedCaseInsensitiveContains(query)
			|| service.containerName.localizedCaseInsensitiveContains(query)
	}

	private var processes: [ManagedService] { store.processServices.filter(matches) }
	private var containers: [ManagedService] { store.dockerServices.filter(matches) }

	private var unmanaged: [DockerContainer] {
		let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !query.isEmpty else { return store.unmanagedContainers }
		return store.unmanagedContainers.filter {
			$0.name.localizedCaseInsensitiveContains(query) || $0.image.localizedCaseInsensitiveContains(query)
		}
	}

	var body: some View {
		NavigationSplitView {
			sidebar
		} detail: {
			detail
		}
		.navigationSplitViewStyle(.balanced)
		.task {
			await store.refreshAll()
			while !Task.isCancelled {
				try? await Task.sleep(for: .seconds(4))
				if Task.isCancelled { break }
				await store.refreshDocker()
			}
		}
		.sheet(item: $editor) { mode in
			switch mode {
			case .add:
				ServiceEditorView(title: "Add Service", store: store) { service in
					store.add(service)
					selection = service.id
				}
			case let .edit(existing):
				ServiceEditorView(title: "Edit Service", store: store, service: existing) { service in
					store.update(service)
				}
			}
		}
		.sheet(item: $sheet) { mode in
			switch mode {
			case .catalog:
				CatalogView(store: store) { service, startNow in
					store.add(service)
					selection = service.id
					if startNow { store.start(service.id) }
				}
			case .folder:
				FolderImportView(store: store) { added, startNow in
					selection = added.first
					if startNow {
						for id in added { store.start(id) }
					}
				}
			case .compose:
				ComposeImportView(store: store) { added in
					selection = added.first
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
			if let error = store.lastError {
				errorToast(error)
			}
		}
	}

	// MARK: - Sidebar

	private var sidebar: some View {
		VStack(spacing: 0) {
			List(selection: $selection) {
				if !processes.isEmpty {
					Section {
						ForEach(processes) { service in
							ServiceRowView(service: service, status: store.status(for: service.id))
								.tag(service.id)
								.contextMenu { serviceMenu(service) }
						}
					} header: {
						sectionHeader("Services", count: processes.count)
					}
				}

				if !containers.isEmpty {
					Section {
						ForEach(containers) { service in
							ServiceRowView(
								service: service,
								status: store.status(for: service.id),
								container: store.container(for: service)
							)
							.tag(service.id)
							.contextMenu { serviceMenu(service) }
						}
					} header: {
						sectionHeader("Docker", count: containers.count)
					}
				}

				if !unmanaged.isEmpty {
					Section {
						ForEach(unmanaged) { container in
							UnmanagedRowView(container: container) {
								let service = store.adopt(container)
								selection = service.id
							}
						}
					} header: {
						sectionHeader("Not managed", count: unmanaged.count)
					}
				}

				if processes.isEmpty, containers.isEmpty, unmanaged.isEmpty {
					emptyState
				}
			}
			.listStyle(.sidebar)
			.searchable(text: $search, placement: .sidebar, prompt: "Filter")

			sidebarFooter
		}
		.navigationSplitViewColumnWidth(min: Theme.sidebarMin, ideal: Theme.sidebarIdeal, max: 340)
		.toolbar {
			ToolbarItemGroup(placement: .primaryAction) {
				Menu {
					Button("Add from Folder…", systemImage: "folder.badge.plus") { sheet = .folder }
						.keyboardShortcut("o", modifiers: [.command])
					Button("Add from Docker…", systemImage: "shippingbox") { sheet = .catalog }
					Divider()
					Button("New Service…", systemImage: "terminal") { editor = .add }
						.keyboardShortcut("n", modifiers: [.command])
					Button("Register Compose File…", systemImage: "doc.badge.plus") { sheet = .compose }
				} label: {
					Label("Add", systemImage: "plus")
				}
				.help("Add a service")

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

	private func sectionHeader(_ title: String, count: Int) -> some View {
		HStack {
			Text(title)
			Spacer()
			Text("\(count)")
				.font(.caption2.weight(.medium))
				.foregroundStyle(.tertiary)
		}
	}

	private var emptyState: some View {
		ContentUnavailableView {
			Label(
				store.services.isEmpty ? "No services" : "No matches",
				systemImage: store.services.isEmpty ? "shippingbox" : "magnifyingglass"
			)
		} description: {
			Text(store.services.isEmpty
				? "Add a local command, or pick a packaged app to run in Docker."
				: "Try another search.")
		}
		.frame(maxWidth: .infinity)
		.padding(.vertical, 24)
		.listRowBackground(Color.clear)
		.listRowSeparator(.hidden)
	}

	private var sidebarFooter: some View {
		VStack(spacing: 0) {
			Divider()
			HStack(spacing: 8) {
				statusPill(
					label: store.dockerAvailability?.summary ?? "Docker…",
					isGood: store.dockerAvailability?.isReady == true,
					symbol: "shippingbox.fill"
				)
				statusPill(
					label: store.portless?.summary ?? "portless…",
					isGood: store.portless?.isReady == true,
					symbol: "bolt.horizontal.fill"
				)
				Spacer(minLength: 0)
			}
			.padding(.horizontal, 12)
			.padding(.vertical, 8)

			Divider()
			Menu {
				Button("Add from Folder…", systemImage: "folder.badge.plus") { sheet = .folder }
				Button("Add from Docker…", systemImage: "shippingbox") { sheet = .catalog }
				Button("New Service…", systemImage: "terminal") { editor = .add }
			} label: {
				Label("Add Service", systemImage: "plus")
					.font(.body.weight(.medium))
					.frame(maxWidth: .infinity)
					.padding(.vertical, 3)
			}
			.menuStyle(.borderlessButton)
			.controlSize(.regular)
			.padding(.horizontal, 12)
			.padding(.vertical, 10)
			.background(.bar)
		}
	}

	private func statusPill(label: String, isGood: Bool, symbol: String) -> some View {
		Label(label, systemImage: symbol)
			.font(.caption2.weight(.medium))
			.foregroundStyle(isGood ? .green : .secondary)
			.lineLimit(1)
			.padding(.horizontal, 7)
			.padding(.vertical, 3)
			.background((isGood ? Color.green : Color.secondary).opacity(0.12), in: Capsule())
	}

	// MARK: - Detail

	@ViewBuilder
	private var detail: some View {
		if let selection, let service = store.find(selection) {
			ServiceDetailView(
				store: store,
				service: service,
				onEdit: { editor = .edit(service) },
				onDelete: {
					store.delete(service.id)
					self.selection = nil
				},
				onShowLog: { showLogFor = service.id }
			)
			.id(service.id)
		} else {
			ContentUnavailableView {
				VStack(spacing: 14) {
					AppLogoView(size: 84)
					Text("Tools UI")
						.font(.system(.title, design: .rounded).weight(.semibold))
				}
			} description: {
				Text("Select a service, or add one to manage local processes and containers like a dock for your tools.")
			} actions: {
				HStack {
					Button("Add from Folder") { sheet = .folder }
						.buttonStyle(.borderedProminent)
					Button("Add from Docker") { sheet = .catalog }
				}
			}
			.frame(maxWidth: .infinity, maxHeight: .infinity)
			.background()
		}
	}

	private func errorToast(_ message: String) -> some View {
		HStack(spacing: 10) {
			Image(systemName: "exclamationmark.triangle.fill")
				.foregroundStyle(.orange)
			Text(message)
				.font(.callout)
				.lineLimit(3)
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
			if !DependencyGraph.dependents(of: service.id, in: store.services).isEmpty {
				Button("Stop with Dependents", systemImage: "square.stack.3d.down.forward") {
					store.stopWithDependents(service.id)
				}
			}
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

// MARK: - Rows

struct ServiceRowView: View {
	let service: ManagedService
	let status: ServiceStatus
	var container: DockerContainer?

	var body: some View {
		HStack(spacing: 12) {
			ServiceAvatar(name: service.name, isRunning: status.isRunning, size: 32)
			VStack(alignment: .leading, spacing: 2) {
				HStack(spacing: 5) {
					Text(service.name)
						.font(.body.weight(.medium))
						.lineLimit(1)
					if !service.dependencies.isEmpty {
						Image(systemName: "arrow.triangle.branch")
							.font(.caption2)
							.foregroundStyle(.tertiary)
							.help("\(service.dependencies.count) dependencies")
					}
					if service.usesPortless {
						Image(systemName: "bolt.horizontal.fill")
							.font(.caption2)
							.foregroundStyle(.tertiary)
							.help("Routed through portless")
					}
				}
				Text(subtitle)
					.font(.caption)
					.foregroundStyle(status.state.tint.opacity(0.9))
					.lineLimit(1)
			}
			Spacer(minLength: 0)
			Circle()
				.fill(status.state.tint)
				.frame(width: 7, height: 7)
				.opacity(status.isRunning ? 1 : 0.35)
		}
		.padding(.vertical, 4)
		.accessibilityElement(children: .combine)
		.accessibilityLabel("\(service.name), \(status.label)")
	}

	private var subtitle: String {
		if let container, !status.state.isBusy {
			return container.status
		}
		return status.label
	}
}

struct UnmanagedRowView: View {
	let container: DockerContainer
	var onAdd: () -> Void

	var body: some View {
		HStack(spacing: 10) {
			Image(systemName: "shippingbox")
				.font(.body)
				.foregroundStyle(.tertiary)
				.frame(width: 22)
			VStack(alignment: .leading, spacing: 1) {
				Text(container.name)
					.font(.callout)
					.lineLimit(1)
				Text(container.composeLabel ?? container.image)
					.font(.caption2)
					.foregroundStyle(.tertiary)
					.lineLimit(1)
					.truncationMode(.middle)
			}
			Spacer(minLength: 0)
			Circle()
				.fill(container.isRunning ? Color.green : Color.secondary)
				.frame(width: 6, height: 6)
				.opacity(container.isRunning ? 1 : 0.35)
			Button(action: onAdd) {
				Image(systemName: "plus.circle")
			}
			.buttonStyle(.plain)
			.foregroundStyle(.secondary)
			.help("Manage this container in Tools UI")
		}
		.padding(.vertical, 2)
	}
}
