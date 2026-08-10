import Foundation

// MARK: - Environment

struct EnvEntry: Identifiable, Codable, Equatable, Hashable {
	var id: UUID
	var key: String
	var value: String
	var isEnabled: Bool

	init(id: UUID = UUID(), key: String = "", value: String = "", isEnabled: Bool = true) {
		self.id = id
		self.key = key
		self.value = value
		self.isEnabled = isEnabled
	}

	init(from decoder: any Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
		key = try container.decodeIfPresent(String.self, forKey: .key) ?? ""
		value = try container.decodeIfPresent(String.self, forKey: .value) ?? ""
		isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
	}

	var trimmedKey: String { key.trimmingCharacters(in: .whitespacesAndNewlines) }

	var isUsable: Bool { isEnabled && !trimmedKey.isEmpty }
}

/// What a `{{token}}` in an env value resolves against — the service that
/// contributed it, not the one consuming it.
struct EnvContext: Equatable, Sendable {
	var name: String = ""
	var host: String = "127.0.0.1"
	var primaryPort: Int?
	var portsByContainerPort: [Int: Int] = [:]
	var url: String = ""

	static let tokenHelp = "{{host}} · {{port}} · {{port:5432}} · {{url}} · {{name}}"
}

enum EnvTemplate {
	/// Expands `{{host}}`, `{{port}}`, `{{port:5432}}`, `{{url}}` and `{{name}}`.
	/// Unknown tokens are left verbatim so a typo is visible rather than silently
	/// becoming an empty string.
	static func expand(_ template: String, context: EnvContext) -> String {
		guard template.contains("{{") else { return template }

		var out = ""
		var rest = Substring(template)

		while let open = rest.range(of: "{{") {
			out += rest[rest.startIndex ..< open.lowerBound]
			let afterOpen = rest[open.upperBound...]
			guard let close = afterOpen.range(of: "}}") else {
				out += rest[open.lowerBound...]
				return out
			}
			let token = afterOpen[afterOpen.startIndex ..< close.lowerBound]
				.trimmingCharacters(in: .whitespaces)
			out += resolve(token, context: context) ?? "{{\(token)}}"
			rest = afterOpen[close.upperBound...]
		}

		out += rest
		return out
	}

	private static func resolve(_ token: String, context: EnvContext) -> String? {
		switch token.lowercased() {
		case "host": return context.host
		case "name": return context.name
		case "url": return context.url
		case "port":
			return context.primaryPort.map(String.init)
		default:
			guard token.lowercased().hasPrefix("port:") else { return nil }
			let wanted = token.dropFirst("port:".count).trimmingCharacters(in: .whitespaces)
			guard let containerPort = Int(wanted) else { return nil }
			// Fall back to the container port itself, which is right for the common
			// case of an unpublished port reached over a shared docker network.
			return String(context.portsByContainerPort[containerPort] ?? containerPort)
		}
	}
}

// MARK: - Docker

struct PortMapping: Identifiable, Codable, Equatable, Hashable {
	var id: UUID
	var hostPort: Int
	var containerPort: Int

	init(id: UUID = UUID(), hostPort: Int, containerPort: Int) {
		self.id = id
		self.hostPort = hostPort
		self.containerPort = containerPort
	}

	init(from decoder: any Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
		hostPort = try container.decodeIfPresent(Int.self, forKey: .hostPort) ?? 0
		containerPort = try container.decodeIfPresent(Int.self, forKey: .containerPort) ?? 0
	}
}

struct DockerRunSpec: Codable, Equatable, Hashable {
	var image: String = ""
	var containerName: String = ""
	var ports: [PortMapping] = []
	var env: [EnvEntry] = []
	var volumes: [String] = []
	var extraArgs: String = ""
	var command: String = ""
	var restartAlways: Bool = false
	/// When set, the image is built from this folder instead of pulled.
	var buildContext: String = ""
	var dockerfile: String = ""

	var isBuilt: Bool { !buildContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

	init(
		image: String = "",
		containerName: String = "",
		ports: [PortMapping] = [],
		env: [EnvEntry] = [],
		volumes: [String] = [],
		extraArgs: String = "",
		command: String = "",
		restartAlways: Bool = false,
		buildContext: String = "",
		dockerfile: String = ""
	) {
		self.image = image
		self.containerName = containerName
		self.ports = ports
		self.env = env
		self.volumes = volumes
		self.extraArgs = extraArgs
		self.command = command
		self.restartAlways = restartAlways
		self.buildContext = buildContext
		self.dockerfile = dockerfile
	}

	init(from decoder: any Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		image = try container.decodeIfPresent(String.self, forKey: .image) ?? ""
		containerName = try container.decodeIfPresent(String.self, forKey: .containerName) ?? ""
		ports = try container.decodeIfPresent([PortMapping].self, forKey: .ports) ?? []
		env = try container.decodeIfPresent([EnvEntry].self, forKey: .env) ?? []
		volumes = try container.decodeIfPresent([String].self, forKey: .volumes) ?? []
		extraArgs = try container.decodeIfPresent(String.self, forKey: .extraArgs) ?? ""
		command = try container.decodeIfPresent(String.self, forKey: .command) ?? ""
		restartAlways = try container.decodeIfPresent(Bool.self, forKey: .restartAlways) ?? false
		buildContext = try container.decodeIfPresent(String.self, forKey: .buildContext) ?? ""
		dockerfile = try container.decodeIfPresent(String.self, forKey: .dockerfile) ?? ""
	}
}

enum DockerBackingKind: String, Codable, Equatable, Hashable {
	/// A container that already existed — we only start/stop it.
	case container
	/// A service inside a compose file.
	case compose
	/// A container this app creates from an image with `docker run`.
	case image
}

struct DockerBinding: Codable, Equatable, Hashable {
	var kind: DockerBackingKind = .container
	var containerName: String = ""
	var composeFile: String = ""
	var composeService: String = ""
	var run: DockerRunSpec = DockerRunSpec()

	/// Which container port portless should route to. 0 means "first published".
	var routedContainerPort: Int = 0
}

// MARK: - Readiness

struct ReadinessCheck: Codable, Equatable, Hashable {
	enum Mode: String, Codable, CaseIterable, Identifiable {
		/// Containers wait for their healthcheck, or for a published port to
		/// accept a connection. Plain processes do not wait.
		case auto
		case immediate
		case tcpPort
		case http
		case dockerHealth

		var id: String { rawValue }

		var label: String {
			switch self {
			case .auto: "Automatic"
			case .immediate: "Don't wait"
			case .tcpPort: "Wait for TCP port"
			case .http: "Wait for HTTP response"
			case .dockerHealth: "Wait for container health"
			}
		}
	}

	var mode: Mode = .auto
	var port: Int = 0
	var url: String = ""
	var timeout: Double = 60

	init(mode: Mode = .auto, port: Int = 0, url: String = "", timeout: Double = 60) {
		self.mode = mode
		self.port = port
		self.url = url
		self.timeout = timeout
	}

	init(from decoder: any Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		mode = try container.decodeIfPresent(Mode.self, forKey: .mode) ?? .auto
		port = try container.decodeIfPresent(Int.self, forKey: .port) ?? 0
		url = try container.decodeIfPresent(String.self, forKey: .url) ?? ""
		timeout = try container.decodeIfPresent(Double.self, forKey: .timeout) ?? 60
	}

	var summary: String {
		switch mode {
		case .auto: "Automatic"
		case .immediate: "No wait"
		case .tcpPort: port > 0 ? "TCP \(port)" : "TCP (auto)"
		case .http: url.isEmpty ? "HTTP (auto)" : "HTTP \(url)"
		case .dockerHealth: "Container healthy"
		}
	}
}
