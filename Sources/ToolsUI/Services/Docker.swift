import Foundation

struct DockerPortBinding: Equatable, Hashable, Sendable, Codable {
	var containerPort: Int
	var networkProtocol: String
	var hostPort: Int?

	var label: String {
		if let hostPort {
			return "\(hostPort)→\(containerPort)/\(networkProtocol)"
		}
		return "\(containerPort)/\(networkProtocol) (unpublished)"
	}
}

struct DockerContainer: Identifiable, Equatable, Sendable {
	var id: String
	var name: String
	var image: String
	var state: String
	var status: String
	var health: String?
	var ports: [DockerPortBinding]
	var env: [String: String]
	var composeProject: String?
	var composeService: String?
	var composeFile: String?

	var isRunning: Bool { state == "running" }

	var hasHealthcheck: Bool { health != nil }
	var isHealthy: Bool { health == "healthy" }

	/// Published host ports, lowest first — the lowest is a good default guess for
	/// the port a user wants routed.
	var publishedPorts: [Int] {
		ports.compactMap(\.hostPort).sorted()
	}

	var primaryHostPort: Int? { publishedPorts.first }

	func hostPort(forContainerPort containerPort: Int) -> Int? {
		ports.first { $0.containerPort == containerPort }?.hostPort
	}

	var composeLabel: String? {
		guard let composeProject, let composeService else { return nil }
		return "\(composeProject)/\(composeService)"
	}
}

enum DockerAvailability: Equatable, Sendable {
	case ready
	case daemonDown
	case notInstalled

	var isReady: Bool { self == .ready }

	var summary: String {
		switch self {
		case .ready: "Ready"
		case .daemonDown: "Docker not running"
		case .notInstalled: "Not installed"
		}
	}

	var hint: String? {
		switch self {
		case .ready: nil
		case .daemonDown: "Docker is installed but the daemon is not responding. Start Docker Desktop and try again."
		case .notInstalled: "The docker CLI was not found on your PATH. Install Docker Desktop to manage containers here."
		}
	}
}

enum Docker {
	static func availability() async -> DockerAvailability {
		let found = await Shell.run("command -v docker", timeout: 8)
		guard found.isSuccess else { return .notInstalled }
		let ping = await Shell.run("docker version --format '{{.Server.Version}}'", timeout: 12)
		return ping.isSuccess ? .ready : .daemonDown
	}

	/// Two calls (ids, then one batched inspect) rather than per-container inspect,
	/// because this runs on a poll while the manager window is open.
	static func snapshot() async -> [DockerContainer] {
		let ids = await Shell.run("docker ps -aq", timeout: 15)
		guard ids.isSuccess else { return [] }
		let list = ids.trimmed.split(whereSeparator: \.isNewline).map(String.init)
		guard !list.isEmpty else { return [] }

		let joined = list.joined(separator: " ")
		let inspected = await Shell.run("docker inspect \(joined)", timeout: 25)
		guard inspected.isSuccess, let data = inspected.output.data(using: .utf8) else { return [] }
		guard let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
		return array.compactMap(parse)
	}

	private static func parse(_ raw: [String: Any]) -> DockerContainer? {
		guard let id = raw["Id"] as? String else { return nil }
		let rawName = (raw["Name"] as? String) ?? ""
		let name = rawName.hasPrefix("/") ? String(rawName.dropFirst()) : rawName

		let config = raw["Config"] as? [String: Any] ?? [:]
		let labels = config["Labels"] as? [String: String] ?? [:]
		let state = raw["State"] as? [String: Any] ?? [:]

		var env: [String: String] = [:]
		for entry in config["Env"] as? [String] ?? [] {
			guard let split = entry.firstIndex(of: "=") else { continue }
			env[String(entry[entry.startIndex ..< split])] = String(entry[entry.index(after: split)...])
		}

		var bindings: [String: Int?] = [:]
		for source in [
			raw["NetworkSettings"] as? [String: Any] ?? [:],
			raw["HostConfig"] as? [String: Any] ?? [:],
		] {
			let key = source["Ports"] != nil ? "Ports" : "PortBindings"
			guard let ports = source[key] as? [String: Any] else { continue }
			for (spec, value) in ports {
				let host = (value as? [[String: Any]])?.compactMap { Int(($0["HostPort"] as? String) ?? "") }.first
				// Running containers report live mappings; keep the first non-nil.
				if bindings[spec] == nil || bindings[spec] == .some(nil) {
					bindings[spec] = host
				}
			}
		}

		let ports: [DockerPortBinding] = bindings.compactMap { spec, host in
			let parts = spec.split(separator: "/")
			guard let portValue = Int(parts.first ?? "") else { return nil }
			return DockerPortBinding(
				containerPort: portValue,
				networkProtocol: parts.count > 1 ? String(parts[1]) : "tcp",
				hostPort: host
			)
		}
		.sorted { $0.containerPort < $1.containerPort }

		return DockerContainer(
			id: id,
			name: name,
			image: (config["Image"] as? String) ?? (raw["Image"] as? String) ?? "",
			state: (state["Status"] as? String) ?? "unknown",
			status: describeState(state),
			health: (state["Health"] as? [String: Any])?["Status"] as? String,
			ports: ports,
			env: env,
			composeProject: labels["com.docker.compose.project"],
			composeService: labels["com.docker.compose.service"],
			composeFile: labels["com.docker.compose.project.config_files"]
		)
	}

	private static func describeState(_ state: [String: Any]) -> String {
		let status = (state["Status"] as? String) ?? "unknown"
		if let health = (state["Health"] as? [String: Any])?["Status"] as? String {
			return "\(status) (\(health))"
		}
		if let code = state["ExitCode"] as? Int, status == "exited" {
			return "exited (\(code))"
		}
		return status
	}

	static func inspectOne(_ name: String) async -> DockerContainer? {
		let result = await Shell.run("docker inspect \(Shell.quote(name))", timeout: 15)
		guard result.isSuccess, let data = result.output.data(using: .utf8) else { return nil }
		guard let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
		return array.compactMap(parse).first
	}

	static func exists(_ name: String) async -> Bool {
		let result = await Shell.run(
			"docker ps -aq --filter name=^/\(name)$ --filter status=created --filter status=exited --filter status=running --filter status=paused --filter status=restarting --filter status=dead",
			timeout: 12
		)
		return result.isSuccess && !result.trimmed.isEmpty
	}

	// MARK: - Lifecycle

	static func start(_ name: String) async -> Shell.Result {
		await Shell.run("docker start \(Shell.quote(name))", timeout: 90)
	}

	static func stop(_ name: String) async -> Shell.Result {
		await Shell.run("docker stop \(Shell.quote(name))", timeout: 90)
	}

	static func remove(_ name: String, force: Bool = true) async -> Shell.Result {
		await Shell.run("docker rm \(force ? "-f " : "")\(Shell.quote(name))", timeout: 60)
	}

	static func composeUp(file: String, service: String?) async -> Shell.Result {
		let target = service.map { " \(Shell.quote($0))" } ?? ""
		return await Shell.run("docker compose -f \(Shell.quote(file)) up -d\(target)", timeout: 240)
	}

	static func composeDown(file: String, service: String?) async -> Shell.Result {
		if let service {
			return await Shell.run("docker compose -f \(Shell.quote(file)) stop \(Shell.quote(service))", timeout: 120)
		}
		return await Shell.run("docker compose -f \(Shell.quote(file)) down", timeout: 180)
	}

	static func composeServices(file: String) async -> [String] {
		let result = await Shell.run(
			"docker compose -f \(Shell.quote(file)) config --services",
			timeout: 45
		)
		guard result.isSuccess else { return [] }
		return result.trimmed.split(whereSeparator: \.isNewline).map(String.init)
	}

	// MARK: - Images

	static func imageExists(_ image: String) async -> Bool {
		await Shell.run("docker image inspect \(Shell.quote(image)) >/dev/null 2>&1", timeout: 20).isSuccess
	}

	/// Ports the image declares via EXPOSE, so a new container can be prefilled
	/// without the user knowing what the app listens on.
	static func exposedPorts(_ image: String) async -> [Int] {
		let result = await Shell.run(
			"docker image inspect \(Shell.quote(image)) --format '{{json .Config.ExposedPorts}}'",
			timeout: 20
		)
		guard result.isSuccess, let data = result.trimmed.data(using: .utf8) else { return [] }
		guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
		return object.keys
			.compactMap { Int($0.split(separator: "/").first ?? "") }
			.sorted()
	}

	static func buildImageCommand(_ spec: DockerRunSpec) -> String {
		var parts = ["docker build", "-t \(Shell.quote(spec.image))"]
		let dockerfile = spec.dockerfile.trimmingCharacters(in: .whitespacesAndNewlines)
		if !dockerfile.isEmpty {
			parts.append("-f \(Shell.quote(dockerfile))")
		}
		parts.append(Shell.quote(spec.buildContext.trimmingCharacters(in: .whitespacesAndNewlines)))
		return parts.joined(separator: " ")
	}

	static func buildRunCommand(_ spec: DockerRunSpec) -> String {
		var parts = ["docker run -d", "--name \(Shell.quote(spec.containerName))"]
		if spec.restartAlways {
			parts.append("--restart unless-stopped")
		}
		for mapping in spec.ports where mapping.hostPort > 0 {
			parts.append("-p 127.0.0.1:\(mapping.hostPort):\(mapping.containerPort)")
		}
		for entry in spec.env where entry.isUsable {
			parts.append("-e \(Shell.quote("\(entry.key)=\(entry.value)"))")
		}
		for volume in spec.volumes where !volume.trimmingCharacters(in: .whitespaces).isEmpty {
			parts.append("-v \(Shell.quote(volume.trimmingCharacters(in: .whitespaces)))")
		}
		let extra = spec.extraArgs.trimmingCharacters(in: .whitespacesAndNewlines)
		if !extra.isEmpty {
			parts.append(extra)
		}
		parts.append(Shell.quote(spec.image))
		let command = spec.command.trimmingCharacters(in: .whitespacesAndNewlines)
		if !command.isEmpty {
			parts.append(command)
		}
		return parts.joined(separator: " ")
	}
}
