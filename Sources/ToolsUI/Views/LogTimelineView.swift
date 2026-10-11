import AppKit
import SwiftUI

extension LogLevel {
	var tint: Color {
		switch self {
		case .fatal, .error: .red
		case .warn: .orange
		case .info: .blue
		case .debug, .trace, .output: .secondary
		}
	}
}

struct LogTimelineView: View {
	@Bindable var store: ServiceStore
	var serviceID: UUID?
	var compact = false
	@State private var query = ""
	@State private var scope = LogScope.all
	@State private var selectedService: UUID?
	@State private var selectedCheckout = ""
	@State private var stream = ""
	@State private var paused = false
	@State private var frozen: [LogEntry] = []
	@State private var follow = true
	@State private var exportError: String?

	private var checkouts: [Checkout] {
		Array(Set(store.runtime.checkouts.values)).sorted { ($0.name, $0.branch, $0.directory) < ($1.name, $1.branch, $1.directory) }
	}

	private var visible: [LogEntry] {
		(paused ? frozen : store.logs.entries).filter { entry in
			guard serviceID == nil || entry.serviceID == serviceID,
				selectedService == nil || entry.serviceID == selectedService,
				stream.isEmpty || entry.stream.rawValue == stream, scope.includes(entry) else { return false }
			let service = store.find(entry.serviceID)
			let checkout = store.runtime.checkout(for: service?.projectDirectory ?? "")
			guard selectedCheckout.isEmpty || checkout?.directory == selectedCheckout else { return false }
			return LogStore.matches(entry, query: query, service: service?.name ?? "Deleted service", checkout: "\(checkout?.name ?? "") \(checkout?.label ?? "")")
		}
	}

	var body: some View {
		VStack(spacing: 0) {
			filters
			Divider()
			let entries = visible
			ScrollViewReader { proxy in
				ScrollView {
					if entries.isEmpty {
						ContentUnavailableView(query.isEmpty && scope == .all ? "No output yet" : "No matching output", systemImage: "text.alignleft",
							description: Text("Logs from services started here appear automatically. Adjust filters to see more."))
							.frame(maxWidth: .infinity, minHeight: compact ? 140 : 250)
					} else {
						LazyVStack(alignment: .leading, spacing: 0) {
							ForEach(entries) { entry in
								LogEntryRow(entry: entry, service: serviceID == nil ? store.find(entry.serviceID)?.name : nil)
								Divider().opacity(0.4)
							}
							Color.clear.frame(height: 1).id("tail")
						}
						.padding(.horizontal, 12)
					}
				}
				.onAppear { if follow, !paused { proxy.scrollTo("tail", anchor: .bottom) } }
				.onChange(of: entries.last) { _, _ in
					if follow, !paused { proxy.scrollTo("tail", anchor: .bottom) }
				}
				.onChange(of: follow) { _, enabled in
					if enabled { proxy.scrollTo("tail", anchor: .bottom) }
				}
			}
			Divider()
			HStack(spacing: 12) {
				Text("\(entries.count) lines\(paused ? " · paused" : " · live")")
					.font(.caption).foregroundStyle(.secondary).monospacedDigit()
				Toggle("Follow", isOn: $follow).toggleStyle(.checkbox).font(.caption)
				Spacer(minLength: 0)
				Menu {
					Button("Copy visible output") { copy(entries) }
					Button("Export text…") { export(entries, json: false) }
					Button("Export JSON lines…") { export(entries, json: true) }
				} label: { Label("Export", systemImage: "square.and.arrow.up") }
				.disabled(entries.isEmpty)
				Button("Clear") {
					if let serviceID { store.clearLog(serviceID) }
					else { for service in store.services { store.clearLog(service.id) } }
					frozen = store.logs.entries
				}.disabled(entries.isEmpty)
			}
			.controlSize(.small).padding(10)
		}
		.onChange(of: paused) { _, enabled in if enabled { frozen = store.logs.entries } }
		.alert("Could not export logs", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
			Button("OK") { exportError = nil }
		} message: { Text(exportError ?? "") }
	}

	private var filters: some View {
		VStack(spacing: 8) {
			HStack(spacing: 8) {
				TextField("Search output, source, service or branch", text: $query)
					.textFieldStyle(.roundedBorder)
				Picker("Severity", selection: $scope) {
					ForEach(LogScope.allCases) { Text($0.rawValue).tag($0) }
				}.labelsHidden().frame(width: compact ? 140 : 160)
				Button {
					paused.toggle()
				} label: { Label(paused ? "Resume" : "Pause", systemImage: paused ? "play.fill" : "pause.fill") }
				.help(paused ? "Resume live output" : "Freeze this view while collection continues")
			}
			if !compact {
				HStack {
					if serviceID == nil {
						Picker("Service", selection: $selectedService) {
							Text("All services").tag(nil as UUID?)
							ForEach(store.services) { Text($0.name).tag(Optional($0.id)) }
						}.labelsHidden()
						Picker("Checkout", selection: $selectedCheckout) {
							Text("All checkouts").tag("")
							ForEach(checkouts) { Text("\($0.name) · \($0.label)").tag($0.directory) }
						}.labelsHidden()
					}
					Picker("Stream", selection: $stream) {
						Text("All streams").tag("")
						ForEach(LogStream.allCases, id: \.self) { Text($0.rawValue).tag($0.rawValue) }
					}.labelsHidden()
					Spacer(minLength: 0)
				}
			}
		}.controlSize(.small).padding(10)
	}

	private func copy(_ entries: [LogEntry]) {
		NSPasteboard.general.clearContents()
		NSPasteboard.general.setString(LogStore.export(entries, names: names, json: false), forType: .string)
	}

	private var names: [UUID: String] { Dictionary(uniqueKeysWithValues: store.services.map { ($0.id, $0.name) }) }

	private func export(_ entries: [LogEntry], json: Bool) {
		let panel = NSSavePanel()
		panel.nameFieldStringValue = "tools-ui-logs.\(json ? "jsonl" : "log")"
		guard panel.runModal() == .OK, let url = panel.url else { return }
		do { try LogStore.export(entries, names: names, json: json).write(to: url, atomically: true, encoding: .utf8) }
		catch { exportError = error.localizedDescription }
	}
}

private struct LogEntryRow: View {
	let entry: LogEntry
	let service: String?
	@State private var showRaw = false

	var body: some View {
		VStack(alignment: .leading, spacing: 5) {
			HStack(spacing: 8) {
				Text(entry.timestamp, format: .dateTime.hour().minute().second().secondFraction(.fractional(3)))
					.monospacedDigit().foregroundStyle(.secondary)
				if let service { Text(service).fontWeight(.medium).lineLimit(1).help(service) }
				Text(entry.parsed.level.label).foregroundStyle(entry.parsed.level.tint).fontWeight(.semibold)
				if !entry.parsed.source.isEmpty { Text(entry.parsed.source).foregroundStyle(.secondary).lineLimit(1) }
				if entry.parsed.isInferred {
					Text("inferred").foregroundStyle(.tertiary).help("Parsed locally by neural-logline. Expand to inspect the original line.")
				}
				Spacer(minLength: 0)
				Text(entry.stream.rawValue).foregroundStyle(.tertiary)
				if entry.raw != entry.parsed.message {
					Button { showRaw.toggle() } label: { Image(systemName: showRaw ? "chevron.up" : "chevron.down") }
						.buttonStyle(.plain).help(showRaw ? "Hide original line" : "Show original line")
						.accessibilityLabel(showRaw ? "Hide original line" : "Show original line")
				}
			}.font(.caption2)
			Text(entry.parsed.message).font(.system(.caption, design: .monospaced))
				.frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
			if showRaw { Text(entry.raw).font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled) }
		}.padding(.vertical, 8)
		.contextMenu {
			Button("Copy original line") {
				NSPasteboard.general.clearContents()
				NSPasteboard.general.setString(entry.raw, forType: .string)
			}
		}
	}
}
