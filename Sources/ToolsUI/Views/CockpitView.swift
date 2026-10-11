import AppKit
import SwiftUI

struct CockpitView: View {
	@Bindable var store: ServiceStore
	var onSelect: (UUID) -> Void
	var onAdd: () -> Void
	@Environment(\.openWindow) private var openWindow
	@State private var search = ""
	@State private var filter = "All"

	private var groups: [CheckoutGroup] { store.runtime.groups(services: store.services) }
	private var visible: [CheckoutGroup] {
		groups.filter { group in
			let text = ([group.name, group.branch, group.id] + group.services.map(\.name) + group.processes.map(\.command) + group.routes.map(\.url)).joined(separator: " ")
			let matches = search.split(whereSeparator: \.isWhitespace).allSatisfy { text.localizedCaseInsensitiveContains($0) }
			let running = group.services.contains { store.status(for: $0.id).isRunning } || !group.processes.isEmpty || group.routes.contains(where: \.isOwnerAlive)
			let attention = group.services.contains { if case .failed = store.status(for: $0.id).state { return true }; return false }
				|| group.routes.contains { !$0.route.isAlias && !$0.isOwnerAlive }
			return matches && (filter == "All" || filter == "Running" && running || filter == "Attention" && attention)
		}
	}

	var body: some View {
		ScrollView {
			VStack(alignment: .leading, spacing: 22) {
				HStack(alignment: .top) {
					VStack(alignment: .leading, spacing: 6) {
						Text("Worktree cockpit").font(.largeTitle.weight(.semibold))
						Text("Your services, checkouts and live routes in one place.").font(.subheadline).foregroundStyle(.secondary)
					}
					Spacer(minLength: 8)
					Button { Task { store.runtime.invalidate(); await store.refreshAll() } } label: { Image(systemName: "arrow.clockwise") }
						.help("Refresh checkouts and resources").disabled(store.runtime.isRefreshing)
				}
				HStack(spacing: 24) {
					summary("Managed running", value: "\(store.services.filter { store.status(for: $0.id).isUp }.count)")
					summary("Checkouts", value: "\(Set(groups.compactMap { $0.checkout?.id }).count)")
					summary("Live routes", value: "\(store.runtime.portless.entries.filter { $0.isOwnerAlive || $0.route.isAlias }.count)")
					Spacer(minLength: 0)
				}
				HStack {
					TextField("Find a repository, branch, service or URL", text: $search).textFieldStyle(.roundedBorder)
					Picker("Show", selection: $filter) { ForEach(["All", "Running", "Attention"], id: \.self) { Text($0) } }
						.labelsHidden().frame(width: 130)
				}
				if let error = store.runtime.error {
					Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange).textSelection(.enabled)
				}
				if visible.isEmpty {
					ContentUnavailableView(groups.isEmpty ? "Add your first service" : "No matching checkouts", systemImage: "square.stack.3d.up",
						description: Text(groups.isEmpty ? "Add a project folder to start managing its services." : "Try another search or status filter."))
					if groups.isEmpty { Button("Add from Folder", action: onAdd).buttonStyle(.borderedProminent) }
				}
				ForEach(visible) { group in checkoutCard(group) }
				if let updated = store.runtime.updatedAt {
					Text("Updated \(updated, style: .time) · CPU includes child processes; memory is resident usage.")
						.font(.caption2).foregroundStyle(.tertiary)
				}
			}
			.padding(28).frame(maxWidth: 1100, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
		}.background()
		.toolbar {
			ToolbarItem(placement: .primaryAction) {
				Button("All Logs", systemImage: "text.alignleft") { openWindow(id: "all-logs") }
			}
		}
	}

	private func summary(_ title: String, value: String) -> some View {
		VStack(alignment: .leading, spacing: 4) {
			Text(value).font(.title2.weight(.semibold)).monospacedDigit()
			Text(title).font(.caption).foregroundStyle(.secondary)
		}
	}

	private func checkoutCard(_ group: CheckoutGroup) -> some View {
		InsetCard {
			VStack(alignment: .leading, spacing: 12) {
				HStack(alignment: .top) {
					VStack(alignment: .leading, spacing: 5) {
						Text(group.name).font(.headline).textSelection(.enabled)
						HStack(spacing: 8) {
							Label(group.branch, systemImage: "arrow.triangle.branch").lineLimit(1).help(group.branch)
							if group.checkout?.isLinked == true { Text("Worktree").foregroundStyle(.blue) }
							if let changed = group.checkout?.changedFiles, changed > 0 { Text("\(changed) changed").foregroundStyle(.orange) }
						}.font(.caption)
					}
					Spacer(minLength: 8)
					UsageLabel(usage: group.usage)
					if !group.id.isEmpty {
						Button { NSWorkspace.shared.open(URL(fileURLWithPath: group.id)) } label: { Image(systemName: "folder") }
							.help("Open checkout folder")
					}
				}
				if !group.id.isEmpty { Text(group.id).font(.caption2.monospaced()).foregroundStyle(.tertiary).textSelection(.enabled).lineLimit(2) }
				ForEach(group.services) { service in
					Divider()
					serviceRow(service)
				}
				ForEach(group.processes) { process in
					Divider()
					externalRow(process, routes: group.routes)
				}
				ForEach(unclaimedRoutes(group)) { route in
					Divider()
					HStack {
						VStack(alignment: .leading, spacing: 4) {
							Text(route.route.hostname).font(.callout.weight(.medium)).lineLimit(1)
							Text("\(route.status) · port \(route.route.port)").font(.caption).foregroundStyle(route.isOwnerAlive || route.route.isAlias ? Color.secondary : .orange)
						}
						Spacer(minLength: 8)
						URLActions(value: route.url)
						Button("Inspect") { openWindow(id: "portless-services") }.controlSize(.small)
					}
				}
			}
		}
	}

	private func unclaimedRoutes(_ group: CheckoutGroup) -> [PortlessEntry] {
		let managed = Set(group.services.compactMap { store.runtime.route(for: $0)?.id })
		let external = Set(group.processes.map(\.pid))
		return group.routes.filter { !managed.contains($0.id) && !external.contains($0.listenerPID ?? $0.route.pid) && !external.contains($0.route.pid) }
	}

	private func serviceRow(_ service: ManagedService) -> some View {
		let status = store.status(for: service.id)
		let route = store.runtime.route(for: service)
		return VStack(alignment: .leading, spacing: 7) {
			HStack(spacing: 10) {
				ServiceAvatar(name: service.name, isRunning: status.isUp, size: 28)
				Button(service.name) { onSelect(service.id) }.buttonStyle(.plain).font(.callout.weight(.medium)).lineLimit(1).help("Show \(service.name)")
				StatusChip(state: status.state)
				Spacer(minLength: 4)
				if let usage = store.runtime.usage(for: service) { UsageLabel(usage: usage) }
				Button { status.isRunning ? store.stop(service.id) : store.start(service.id) } label: { Image(systemName: status.isRunning ? "stop.fill" : "play.fill") }
					.help(status.isRunning ? "Stop \(service.name)" : "Start \(service.name)")
					.accessibilityLabel(status.isRunning ? "Stop \(service.name)" : "Start \(service.name)")
			}
			if !store.effectiveURL(for: service).isEmpty {
				HStack {
					URLActions(value: store.effectiveURL(for: service), showURL: true)
					Text(route == nil ? "Configured" : "Live · port \(route?.route.port ?? 0)").font(.caption2).foregroundStyle(route == nil ? Color.secondary : .green)
					Spacer(minLength: 0)
				}
			}
			if case let .failed(message) = status.state {
				Text(message).font(.caption).foregroundStyle(.red).textSelection(.enabled)
			} else if case let .waitingForDependencies(name) = status.state {
				Text("Waiting for \(name)").font(.caption).foregroundStyle(.orange)
			}
		}
	}

	private func externalRow(_ process: DeveloperProcess, routes: [PortlessEntry]) -> some View {
		let pids = ResourceUsage.tree(process.pid, in: store.runtime.samples)
		let route = routes.first { pids.contains($0.route.pid) || pids.contains($0.listenerPID ?? 0) }
		return VStack(alignment: .leading, spacing: 6) {
			HStack {
				Label(route != nil && process.command.contains("portless") ? "Portless · \(route?.route.hostname ?? process.process)" : process.process, systemImage: "terminal").font(.callout.weight(.medium))
				Spacer(minLength: 8)
				UsageLabel(usage: ResourceUsage.total(pids, in: store.runtime.samples))
				Button("Inspect") { openWindow(id: "process-finder") }.controlSize(.small)
			}
			Text("Started outside Tools UI · PID \(process.pid)\(process.listeningPorts.isEmpty ? "" : " · ports " + process.listeningPorts.map(String.init).joined(separator: ", "))")
				.font(.caption2).foregroundStyle(.secondary)
			Text(process.command).font(.caption2.monospaced()).foregroundStyle(.tertiary).lineLimit(2).textSelection(.enabled)
			if let route { URLActions(value: route.url, showURL: true) }
		}
	}
}

struct UsageLabel: View {
	let usage: ResourceUsage
	var body: some View {
		HStack(spacing: 9) {
			Text(usage.cpuText)
			Text(usage.memoryText)
		}.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
			.help("CPU includes descendants and may exceed 100% across cores. Resident memory is summed across \(usage.processCount) processes; Docker uses container stats.")
			.accessibilityLabel("CPU \(usage.cpuText), memory \(usage.memoryText)")
	}
}

struct URLActions: View {
	let value: String
	var showURL = false
	var body: some View {
		HStack(spacing: 8) {
			if showURL { Text(value).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).textSelection(.enabled).help(value) }
			Button {
				if let url = URL(string: value) { NSWorkspace.shared.open(url) }
			} label: { Image(systemName: "safari") }
				.buttonStyle(.plain).help("Open \(value)").accessibilityLabel("Open URL")
			Button {
				NSPasteboard.general.clearContents()
				NSPasteboard.general.setString(value, forType: .string)
			} label: { Image(systemName: "doc.on.doc") }
				.buttonStyle(.plain).help("Copy URL").accessibilityLabel("Copy URL")
		}
	}
}
