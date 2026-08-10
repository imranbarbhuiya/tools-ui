import AppKit
import Foundation
import Observation

@Observable
@MainActor
final class ServiceStore {
	var services: [ManagedService] = []
	var statuses: [UUID: ServiceStatus] = [:]
	var lastError: String?
	var portlessHealth: Portless.Health?

	private let runners = ProcessManager()
	private let saveURL: URL

	init() {
		let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
			.appendingPathComponent("ToolsUI", isDirectory: true)
		try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		saveURL = dir.appendingPathComponent("services.json")
		load()
		if services.isEmpty {
			services = Self.seed
			save()
		}
		for service in services {
			statuses[service.id] = ServiceStatus()
		}
		for service in services where service.autoStart {
			start(service.id)
		}
	}

	var anyRunning: Bool {
		statuses.values.contains { $0.isRunning }
	}

	var anyUsesPortless: Bool {
		services.contains { $0.usesPortless }
	}

	func refreshPortlessHealth() async {
		portlessHealth = await Portless.health()
	}

	func status(for id: UUID) -> ServiceStatus {
		statuses[id] ?? ServiceStatus()
	}

	func add(_ service: ManagedService) {
		services.append(service)
		statuses[service.id] = ServiceStatus()
		save()
	}

	func update(_ service: ManagedService) {
		guard let i = services.firstIndex(where: { $0.id == service.id }) else { return }
		services[i] = service
		save()
	}

	func delete(_ id: UUID) {
		stop(id)
		services.removeAll { $0.id == id }
		statuses[id] = nil
		save()
	}

	func move(from source: IndexSet, to destination: Int) {
		services.move(fromOffsets: source, toOffset: destination)
		save()
	}

	func start(_ id: UUID) {
		guard let service = services.first(where: { $0.id == id }) else { return }
		var st = status(for: id)
		if st.isRunning { return }
		st.state = .starting
		st.log = ""
		st.startedAt = Date()
		statuses[id] = st
		lastError = nil

		runners.start(service: service) { [weak self] event in
			Task { @MainActor in
				self?.handle(event, for: id)
			}
		}

		if service.usesPortless {
			Task { [weak self] in
				let health = await Portless.health()
				self?.portlessHealth = health
				if let hint = health.hint {
					self?.lastError = "\(service.name): \(hint)"
				}
			}
		}
	}

	func stop(_ id: UUID) {
		runners.stop(id: id)
		var st = status(for: id)
		st.state = .stopped
		st.startedAt = nil
		statuses[id] = st
	}

	func restart(_ id: UUID) {
		stop(id)
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
			self?.start(id)
		}
	}

	func openURL(_ id: UUID) {
		guard let service = services.first(where: { $0.id == id }) else { return }
		let trimmed = service.effectiveURL
		guard !trimmed.isEmpty, let url = URL(string: trimmed) else { return }
		NSWorkspace.shared.open(url)
	}

	func openFolder(_ id: UUID) {
		guard let service = services.first(where: { $0.id == id }) else { return }
		let path = service.workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !path.isEmpty else { return }
		NSWorkspace.shared.open(URL(fileURLWithPath: path, isDirectory: true))
	}

	func clearLog(_ id: UUID) {
		var st = status(for: id)
		st.log = ""
		statuses[id] = st
	}

	func stopAll() {
		for service in services {
			stop(service.id)
		}
	}

	private func handle(_ event: ProcessManager.Event, for id: UUID) {
		var st = status(for: id)
		switch event {
		case let .started(pid):
			st.state = .running(pid: pid)
			st.startedAt = Date()
		case let .output(chunk):
			st.log = appendLog(st.log, chunk)
		case let .exited(code):
			if case .stopped = st.state {
				break
			}
			if code == 0 {
				st.state = .stopped
			} else {
				st.state = .failed("exit \(code)")
				lastError = "\(services.first(where: { $0.id == id })?.name ?? "Service") exited \(code)"
			}
			st.startedAt = nil
		case let .failed(message):
			st.state = .failed(message)
			st.startedAt = nil
			lastError = message
		}
		statuses[id] = st
	}

	private func appendLog(_ existing: String, _ chunk: String) -> String {
		let next = existing.isEmpty ? chunk : existing + chunk
		if next.count > 40_000 {
			return String(next.suffix(30_000))
		}
		return next
	}

	private func load() {
		guard let data = try? Data(contentsOf: saveURL) else { return }
		guard let decoded = try? JSONDecoder().decode([ManagedService].self, from: data) else { return }
		services = decoded
	}

	func save() {
		guard let data = try? JSONEncoder().encode(services) else { return }
		try? data.write(to: saveURL, options: .atomic)
	}

	private static var seed: [ManagedService] {
		let home = FileManager.default.homeDirectoryForCurrentUser.path
		return [
			ManagedService(
				name: "Frameforge",
				workingDirectory: "\(home)/Documents/open-source/parse-video",
				command: "bun run start",
				url: "http://localhost:3456",
				autoStart: false,
				notes: "Video frame parser"
			),
		]
	}
}
