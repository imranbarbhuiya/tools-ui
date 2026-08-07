import Foundation

struct ManagedService: Identifiable, Codable, Equatable, Hashable {
	var id: UUID
	var name: String
	var workingDirectory: String
	var command: String
	var url: String
	var autoStart: Bool
	var notes: String

	init(
		id: UUID = UUID(),
		name: String,
		workingDirectory: String = "",
		command: String,
		url: String = "",
		autoStart: Bool = false,
		notes: String = ""
	) {
		self.id = id
		self.name = name
		self.workingDirectory = workingDirectory
		self.command = command
		self.url = url
		self.autoStart = autoStart
		self.notes = notes
	}
}

enum ServiceRunState: Equatable {
	case stopped
	case starting
	case running(pid: Int32)
	case failed(String)
}

struct ServiceStatus: Equatable {
	var state: ServiceRunState = .stopped
	var log: String = ""
	var startedAt: Date?

	var isRunning: Bool {
		if case .running = state { return true }
		if case .starting = state { return true }
		return false
	}

	var pidText: String {
		if case let .running(pid) = state { return String(pid) }
		return "—"
	}

	var label: String {
		switch state {
		case .stopped: "Stopped"
		case .starting: "Starting…"
		case .running: "Running"
		case let .failed(message): "Failed: \(message)"
		}
	}
}
