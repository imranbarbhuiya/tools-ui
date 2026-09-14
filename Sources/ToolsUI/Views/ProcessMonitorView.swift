import AppKit
import SwiftUI

struct ProcessMonitorView: View {
	@Bindable var monitor: ProcessMonitor
	@State private var search = ""
	@State private var selection: PortListener.ID?
	@State private var pendingTermination: PortListener?

	private var rows: [PortListener] {
		let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !query.isEmpty else { return monitor.displayedListeners }
		return monitor.displayedListeners.filter {
			$0.process.localizedCaseInsensitiveContains(query)
				|| $0.command.localizedCaseInsensitiveContains(query)
				|| $0.parentProcess.localizedCaseInsensitiveContains(query)
				|| String($0.port).contains(query)
				|| $0.kind.rawValue.localizedCaseInsensitiveContains(query)
		}
	}

	private var uniquePortCount: Int { Set(monitor.displayedListeners.map(\.port)).count }
	private var forwardedPortCount: Int { Set(monitor.listeners.filter { $0.kind == .forwarded }.map(\.port)).count }

	var body: some View {
		VStack(spacing: 0) {
			header
			Divider()
			if let error = monitor.error { errorView(error) }
			else if monitor.updatedAt == nil { loadingView }
			else if rows.isEmpty { emptyView }
			else { table }
		}
		.background(.background)
		.searchable(text: $search, prompt: "Process, port, or type")
		.task {
			await monitor.refresh()
			while !Task.isCancelled {
				try? await Task.sleep(for: .seconds(5))
				await monitor.refresh()
			}
		}
		.onChange(of: monitor.showSystem) { _, _ in Task { await monitor.refresh() } }
		.confirmationDialog(
			pendingTermination.map { "Terminate \($0.process)?" } ?? "Terminate process?",
			isPresented: Binding(
				get: { pendingTermination != nil },
				set: { if !$0 { pendingTermination = nil } }
			),
			presenting: pendingTermination
		) { listener in
			Button("Terminate PID \(listener.pid)", role: .destructive) {
				pendingTermination = nil
				Task { await monitor.terminate(listener) }
			}
			Button("Cancel", role: .cancel) { pendingTermination = nil }
		} message: { listener in
			Text("This sends SIGTERM to the process started with:\n\(listener.command)")
		}
		.toolbar {
			ToolbarItemGroup {
				Toggle(isOn: $monitor.showSystem) { Label("System processes", systemImage: "gearshape.2") }
				Button { Task { await monitor.refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
					.disabled(monitor.isRefreshing)
			}
		}
	}

	private var header: some View {
		HStack(alignment: .top, spacing: 28) {
			VStack(alignment: .leading, spacing: 5) {
				Text("Network activity")
					.font(.system(.title, design: .rounded, weight: .bold))
				Text("Listening ports and the processes behind them")
					.foregroundStyle(.secondary)
			}
			Spacer()
			Metric(value: uniquePortCount, label: "Ports", color: .blue)
			Metric(value: forwardedPortCount, label: "Forwarded", color: .orange)
			Metric(value: monitor.visibleProcessCount, label: "Your processes", color: .green)
			if monitor.showSystem { Metric(value: monitor.totalProcessCount, label: "All processes", color: .secondary) }
		}
		.padding(.horizontal, 24)
		.padding(.vertical, 20)
		.background(.bar)
	}

	private var table: some View {
		Table(rows, selection: $selection) {
			TableColumn("Port") { row in Text(String(row.port)).font(.body.monospaced().weight(.semibold)) }.width(min: 72, ideal: 88)
			TableColumn("Process") { row in
				VStack(alignment: .leading, spacing: 2) {
					Text(row.process).fontWeight(.medium)
					HStack(spacing: 5) {
						Text("PID \(row.pid)")
						if !row.parentProcess.isEmpty {
							Text("· Started by \(row.parentProcess)")
						}
					}
					.font(.caption.monospaced())
					.foregroundStyle(.tertiary)
					.help(row.parentProcess.isEmpty ? "PID \(row.pid)" : "Started by \(row.parentProcess) (PID \(row.parentPID))")
				}
			}.width(min: 160, ideal: 240)
			TableColumn("Type") { row in KindBadge(kind: row.kind) }.width(min: 105, ideal: 120)
			TableColumn("Listening on") { row in Text(row.endpoint).font(.callout.monospaced()).textSelection(.enabled) }.width(min: 140, ideal: 190)
			TableColumn("Started with") { row in CommandCell(command: row.command) }
			TableColumn("") { row in
				if row.kind != .system {
					Button {
						pendingTermination = row
					} label: {
						Image(systemName: "stop.circle")
					}
					.buttonStyle(.borderless)
					.foregroundStyle(.secondary)
					.help("Terminate \(row.process) (PID \(row.pid))")
				}
			}.width(32)
		}
		.contextMenu(forSelectionType: PortListener.ID.self) { ids in
			if let id = ids.first, let row = rows.first(where: { $0.id == id }) {
				Button("Copy port") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(String(row.port), forType: .string) }
				Button("Copy command") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(row.command, forType: .string) }
				if row.kind != .system {
					Divider()
					Button("Terminate process…", systemImage: "stop.circle", role: .destructive) { pendingTermination = row }
				}
			}
		}
	}

	private var loadingView: some View { ContentUnavailableView { Label("Inspecting this Mac…", systemImage: "point.3.connected.trianglepath.dotted") }.frame(maxWidth: .infinity, maxHeight: .infinity) }
	private var emptyView: some View { ContentUnavailableView("No listening ports", systemImage: "checkmark.circle", description: Text(search.isEmpty ? "No user-facing listeners are active." : "Try a different search." )).frame(maxWidth: .infinity, maxHeight: .infinity) }
	private func errorView(_ message: String) -> some View { ContentUnavailableView("Inspection failed", systemImage: "exclamationmark.triangle", description: Text(message)).frame(maxWidth: .infinity, maxHeight: .infinity) }
}

private struct Metric: View {
	let value: Int
	let label: String
	let color: Color
	var body: some View {
		VStack(alignment: .leading, spacing: 2) {
			Text(value, format: .number).font(.system(.title2, design: .rounded, weight: .bold)).foregroundStyle(color)
			Text(label).font(.caption).foregroundStyle(.secondary)
		}.frame(minWidth: 78, alignment: .leading)
	}
}

private struct KindBadge: View {
	let kind: ListenerKind
	private var color: Color { switch kind { case .local: .blue; case .forwarded: .orange; case .system: .secondary } }
	var body: some View {
		Label(kind.rawValue, systemImage: kind.symbol)
			.font(.caption.weight(.semibold)).foregroundStyle(color)
			.padding(.horizontal, 8).padding(.vertical, 4)
			.background(color.opacity(0.12), in: Capsule())
	}
}

private struct CommandCell: View {
	let command: String
	@State private var isHovering = false

	private var displayCommand: String {
		command.replacingOccurrences(of: NSHomeDirectory(), with: "~")
	}

	private var wrappableCommand: String {
		displayCommand
			.replacingOccurrences(of: "/", with: "/\u{200B}")
			.replacingOccurrences(of: " ", with: " \u{200B}")
	}

	var body: some View {
		Text(displayCommand)
			.font(.callout.monospaced())
			.lineLimit(1)
			.truncationMode(.middle)
			.frame(maxWidth: .infinity, alignment: .leading)
			.contentShape(Rectangle())
			.onHover { hovering in
				isHovering = hovering && !command.isEmpty
			}
			.popover(isPresented: $isHovering, arrowEdge: .bottom) {
				Text(wrappableCommand)
					.font(.callout.monospaced())
					.textSelection(.enabled)
					.lineLimit(nil)
					.fixedSize(horizontal: false, vertical: true)
					.frame(width: 620, alignment: .leading)
					.padding(12)
			}
	}
}
