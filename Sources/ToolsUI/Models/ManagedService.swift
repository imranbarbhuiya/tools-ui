import Foundation

enum ServiceKind: String, Codable, Equatable, Hashable {
	case process
	case docker

	var label: String {
		switch self {
		case .process: "Process"
		case .docker: "Docker"
		}
	}

	var symbol: String {
		switch self {
		case .process: "terminal"
		case .docker: "shippingbox.fill"
		}
	}
}

struct ManagedService: Identifiable, Codable, Equatable, Hashable {
	var id: UUID
	var name: String
	var kind: ServiceKind
	var workingDirectory: String
	var command: String
	var url: String
	var autoStart: Bool
	var notes: String
	var portlessEnabled: Bool
	var portlessName: String

	var docker: DockerBinding
	var dependencies: [UUID]
	/// Exported to every service that depends on this one.
	var providedEnv: [EnvEntry]
	/// Applied to this service's own process, winning over inherited values.
	var envOverrides: [EnvEntry]
	var readiness: ReadinessCheck

	init(
		id: UUID = UUID(),
		name: String,
		kind: ServiceKind = .process,
		workingDirectory: String = "",
		command: String = "",
		url: String = "",
		autoStart: Bool = false,
		notes: String = "",
		portlessEnabled: Bool = false,
		portlessName: String = "",
		docker: DockerBinding = DockerBinding(),
		dependencies: [UUID] = [],
		providedEnv: [EnvEntry] = [],
		envOverrides: [EnvEntry] = [],
		readiness: ReadinessCheck = ReadinessCheck()
	) {
		self.id = id
		self.name = name
		self.kind = kind
		self.workingDirectory = workingDirectory
		self.command = command
		self.url = url
		self.autoStart = autoStart
		self.notes = notes
		self.portlessEnabled = portlessEnabled
		self.portlessName = portlessName
		self.docker = docker
		self.dependencies = dependencies
		self.providedEnv = providedEnv
		self.envOverrides = envOverrides
		self.readiness = readiness
	}

	init(from decoder: any Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		id = try container.decode(UUID.self, forKey: .id)
		name = try container.decode(String.self, forKey: .name)
		kind = try container.decodeIfPresent(ServiceKind.self, forKey: .kind) ?? .process
		command = try container.decodeIfPresent(String.self, forKey: .command) ?? ""
		workingDirectory = try container.decodeIfPresent(String.self, forKey: .workingDirectory) ?? ""
		url = try container.decodeIfPresent(String.self, forKey: .url) ?? ""
		autoStart = try container.decodeIfPresent(Bool.self, forKey: .autoStart) ?? false
		notes = try container.decodeIfPresent(String.self, forKey: .notes) ?? ""
		portlessEnabled = try container.decodeIfPresent(Bool.self, forKey: .portlessEnabled) ?? false
		portlessName = try container.decodeIfPresent(String.self, forKey: .portlessName) ?? ""
		docker = try container.decodeIfPresent(DockerBinding.self, forKey: .docker) ?? DockerBinding()
		dependencies = try container.decodeIfPresent([UUID].self, forKey: .dependencies) ?? []
		providedEnv = try container.decodeIfPresent([EnvEntry].self, forKey: .providedEnv) ?? []
		envOverrides = try container.decodeIfPresent([EnvEntry].self, forKey: .envOverrides) ?? []
		readiness = try container.decodeIfPresent(ReadinessCheck.self, forKey: .readiness) ?? ReadinessCheck()
	}

	var isDocker: Bool { kind == .docker }

	/// The container this service drives, whichever way it is backed.
	var containerName: String {
		switch docker.kind {
		case .compose:
			docker.containerName.isEmpty ? docker.composeService : docker.containerName
		case .container, .image:
			docker.containerName
		}
	}

	// MARK: - Portless

	var resolvedPortlessName: String {
		let typed = portlessName.trimmingCharacters(in: .whitespacesAndNewlines)
		return Portless.slug(from: typed.isEmpty ? name : typed)
	}

	var usesPortless: Bool {
		portlessEnabled && !resolvedPortlessName.isEmpty
	}

	func portlessURL(proxy: Portless.Probe?) -> String {
		Portless.url(name: resolvedPortlessName, proxy: proxy)
	}

	func effectiveURL(proxy: Portless.Probe?) -> String {
		usesPortless ? portlessURL(proxy: proxy) : url.trimmingCharacters(in: .whitespacesAndNewlines)
	}

	var launchCommand: String {
		let base = command.trimmingCharacters(in: .whitespacesAndNewlines)
		guard usesPortless, kind == .process else { return base }
		return Portless.wrap(command: base, name: resolvedPortlessName)
	}
}

enum ServiceRunState: Equatable {
	case stopped
	case waitingForDependencies(String)
	case starting
	case running(pid: Int32)
	case failed(String)

	var isBusy: Bool {
		switch self {
		case .starting, .waitingForDependencies: true
		default: false
		}
	}
}

struct ServiceStatus: Equatable {
	var state: ServiceRunState = .stopped
	var log: String = ""
	var startedAt: Date?

	var isRunning: Bool {
		switch state {
		case .running, .starting, .waitingForDependencies: true
		case .stopped, .failed: false
		}
	}

	/// True only when the service is actually up, not merely mid-launch.
	var isUp: Bool {
		if case .running = state { return true }
		return false
	}

	var pidText: String {
		if case let .running(pid) = state, pid > 0 { return String(pid) }
		return "—"
	}

	var label: String {
		switch state {
		case .stopped: "Stopped"
		case let .waitingForDependencies(name): "Waiting for \(name)…"
		case .starting: "Starting…"
		case .running: "Running"
		case let .failed(message): "Failed: \(message)"
		}
	}
}
