import Foundation

struct ManagedService: Identifiable, Codable, Equatable, Hashable {
	var id: UUID
	var name: String
	var workingDirectory: String
	var command: String
	var url: String
	var autoStart: Bool
	var notes: String
	var portlessEnabled: Bool
	var portlessName: String

	init(
		id: UUID = UUID(),
		name: String,
		workingDirectory: String = "",
		command: String,
		url: String = "",
		autoStart: Bool = false,
		notes: String = "",
		portlessEnabled: Bool = false,
		portlessName: String = ""
	) {
		self.id = id
		self.name = name
		self.workingDirectory = workingDirectory
		self.command = command
		self.url = url
		self.autoStart = autoStart
		self.notes = notes
		self.portlessEnabled = portlessEnabled
		self.portlessName = portlessName
	}

	init(from decoder: any Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		id = try container.decode(UUID.self, forKey: .id)
		name = try container.decode(String.self, forKey: .name)
		command = try container.decode(String.self, forKey: .command)
		workingDirectory = try container.decodeIfPresent(String.self, forKey: .workingDirectory) ?? ""
		url = try container.decodeIfPresent(String.self, forKey: .url) ?? ""
		autoStart = try container.decodeIfPresent(Bool.self, forKey: .autoStart) ?? false
		notes = try container.decodeIfPresent(String.self, forKey: .notes) ?? ""
		portlessEnabled = try container.decodeIfPresent(Bool.self, forKey: .portlessEnabled) ?? false
		portlessName = try container.decodeIfPresent(String.self, forKey: .portlessName) ?? ""
	}

	var resolvedPortlessName: String {
		let typed = portlessName.trimmingCharacters(in: .whitespacesAndNewlines)
		return Portless.slug(from: typed.isEmpty ? name : typed)
	}

	var usesPortless: Bool {
		portlessEnabled && !resolvedPortlessName.isEmpty
	}

	var portlessURL: String {
		Portless.url(name: resolvedPortlessName)
	}

	/// The URL to open: derived from the portless hostname when routing is on,
	/// otherwise whatever was typed by hand.
	var effectiveURL: String {
		usesPortless ? portlessURL : url.trimmingCharacters(in: .whitespacesAndNewlines)
	}

	var launchCommand: String {
		let base = command.trimmingCharacters(in: .whitespacesAndNewlines)
		guard usesPortless else { return base }
		return Portless.wrap(command: base, name: resolvedPortlessName)
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
