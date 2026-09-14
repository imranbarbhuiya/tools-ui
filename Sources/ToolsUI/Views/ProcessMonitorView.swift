import AppKit
import SwiftUI

struct ProcessMonitorView: View {
	private enum Section: String, CaseIterable, Identifiable {
		case ports = "Listening ports"
		case processes = "Developer processes"
		var id: Self { self }
	}

	@Bindable var monitor: ProcessMonitor
	@State private var section: Section = .ports
	@State private var search = ""
	@State private var selection: PortListener.ID?
	@State private var pendingTermination: PortListener?
	@State private var processSelection: DeveloperProcess.ID?
	@State private var pendingProcessTermination: DeveloperProcess?

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

	private var processRows: [DeveloperProcess] {
		let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !query.isEmpty else { return monitor.developerProcesses }
		return monitor.developerProcesses.filter {
			$0.process.localizedCaseInsensitiveContains(query)
				|| $0.command.localizedCaseInsensitiveContains(query)
				|| $0.workingDirectory.localizedCaseInsensitiveContains(query)
				|| $0.parentProcess.localizedCaseInsensitiveContains(query)
				|| String($0.pid).contains(query)
		}
	}

	private var uniquePortCount: Int { Set(monitor.displayedListeners.map(\.port)).count }
	private var forwardedPortCount: Int { Set(monitor.listeners.filter { $0.kind.isForwarded }.map(\.port)).count }

	var body: some View {
		VStack(spacing: 0) {
			header
			Divider()
			if let error = monitor.error { errorView(error) }
			else if monitor.updatedAt == nil { loadingView }
			else if section == .ports, rows.isEmpty { emptyView }
			else if section == .processes, processRows.isEmpty { emptyView }
			else if section == .ports { table }
			else { processTable }
		}
		.background(.background)
		.searchable(text: $search, prompt: section == .ports ? "Process, port, or direction" : "Process, command, or folder")
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
		.confirmationDialog(
			pendingProcessTermination.map { "Terminate \($0.process)?" } ?? "Terminate process?",
			isPresented: Binding(
				get: { pendingProcessTermination != nil },
				set: { if !$0 { pendingProcessTermination = nil } }
			),
			presenting: pendingProcessTermination
		) { process in
			Button("Terminate PID \(process.pid)", role: .destructive) {
				pendingProcessTermination = nil
				Task { await monitor.terminate(process) }
			}
			Button("Cancel", role: .cancel) { pendingProcessTermination = nil }
		} message: { process in
			Text("This sends SIGTERM to the process started with:\n\(process.command)")
		}
		.toolbar {
			ToolbarItemGroup {
				Picker("View", selection: $section) {
					ForEach(Section.allCases) { section in Text(section.rawValue).tag(section) }
				}
				.pickerStyle(.segmented)
				.frame(width: 270)
				Toggle(isOn: $monitor.showSystem) { Label("System processes", systemImage: "gearshape.2") }
					.disabled(section == .processes)
				Button { Task { await monitor.refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
					.disabled(monitor.isRefreshing)
			}
		}
	}

	private var header: some View {
		HStack(alignment: .top, spacing: 28) {
			VStack(alignment: .leading, spacing: 5) {
				Text(section == .ports ? "Network activity" : "Developer processes")
					.font(.system(.title, design: .rounded, weight: .bold))
				Text(section == .ports ? "Listening ports and the processes behind them" : "Likely project processes, including those without ports")
					.foregroundStyle(.secondary)
			}
			Spacer()
			if section == .ports {
				Metric(value: uniquePortCount, label: "Ports", color: .blue)
				Metric(value: forwardedPortCount, label: "Forwarded", color: .orange)
			} else {
				Metric(value: monitor.developerProcesses.count, label: "Detected", color: .blue)
				Metric(value: monitor.developerProcesses.filter { $0.listeningPorts.isEmpty }.count, label: "Portless", color: .orange)
			}
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
			TableColumn("Direction") { row in KindBadge(kind: row.kind) }.width(min: 120, ideal: 145)
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

	private var processTable: some View {
		Table(processRows, selection: $processSelection) {
			TableColumn("Process") { process in
				VStack(alignment: .leading, spacing: 2) {
					Text(process.process).fontWeight(.medium)
					Text("PID \(process.pid)" + (process.parentProcess.isEmpty ? "" : " · Started by \(process.parentProcess)"))
						.font(.caption.monospaced()).foregroundStyle(.tertiary)
				}
			}.width(min: 170, ideal: 240)
			TableColumn("Ports") { process in
				Text(process.listeningPorts.isEmpty ? "No listening ports" : process.listeningPorts.map(String.init).joined(separator: ", "))
					.font(.callout.monospaced())
					.foregroundStyle(process.listeningPorts.isEmpty ? .secondary : .primary)
			}.width(min: 130, ideal: 160)
			TableColumn("Working directory") { process in CommandCell(command: process.workingDirectory) }.width(min: 180, ideal: 260)
			TableColumn("Started with") { process in CommandCell(command: process.command) }
			TableColumn("") { process in
				Button { pendingProcessTermination = process } label: { Image(systemName: "stop.circle") }
					.buttonStyle(.borderless).foregroundStyle(.secondary)
					.help("Terminate \(process.process) (PID \(process.pid))")
			}.width(32)
		}
		.contextMenu(forSelectionType: DeveloperProcess.ID.self) { ids in
			if let id = ids.first, let process = processRows.first(where: { $0.id == id }) {
				Button("Copy command") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(process.command, forType: .string) }
				Button("Copy working directory") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(process.workingDirectory, forType: .string) }
				Divider()
				Button("Terminate process…", systemImage: "stop.circle", role: .destructive) { pendingProcessTermination = process }
			}
		}
	}

	private var loadingView: some View { ContentUnavailableView { Label("Inspecting this Mac…", systemImage: "point.3.connected.trianglepath.dotted") }.frame(maxWidth: .infinity, maxHeight: .infinity) }
	private var emptyView: some View {
		ContentUnavailableView(
			section == .ports ? "No listening ports" : "No developer processes",
			systemImage: "checkmark.circle",
			description: Text(search.isEmpty ? (section == .ports ? "No user-facing listeners are active." : "No likely project processes are running.") : "Try a different search.")
		).frame(maxWidth: .infinity, maxHeight: .infinity)
	}
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
	private var color: Color {
		switch kind {
		case .local: .blue
		case .usesRemote: .teal
		case .publishesLocal: .orange
		case .forwarded: .yellow
		case .system: .secondary
		}
	}
	var body: some View {
		Label(kind.rawValue, systemImage: kind.symbol)
			.font(.caption.weight(.semibold)).foregroundStyle(color)
			.padding(.horizontal, 8).padding(.vertical, 4)
			.background(color.opacity(0.12), in: Capsule())
			.help(kind.explanation)
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
