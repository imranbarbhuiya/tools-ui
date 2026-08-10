import Foundation

/// What a project folder looks like from the outside: the docker definitions it
/// ships, and the command it would otherwise be started with.
struct FolderScan: Equatable, Sendable {
	var path: String = ""
	var projectName: String = ""
	var composeFiles: [String] = []
	var dockerfiles: [String] = []
	var packageManager: String = "npm"
	var scripts: [String] = []
	var suggestedScript: String = ""
	var suggestedCommand: String = ""
	var dockerfilePorts: [Int] = []

	var hasCompose: Bool { !composeFiles.isEmpty }
	var hasDockerfile: Bool { !dockerfiles.isEmpty }
	var hasDocker: Bool { hasCompose || hasDockerfile }

	var summary: String {
		var parts: [String] = []
		if hasCompose { parts.append("\(composeFiles.count) compose file\(composeFiles.count == 1 ? "" : "s")") }
		if hasDockerfile { parts.append("Dockerfile") }
		if !suggestedCommand.isEmpty { parts.append("`\(suggestedCommand)`") }
		return parts.isEmpty ? "No docker config or package script found." : parts.joined(separator: " · ")
	}

	private static let composeNames = [
		"compose.yaml", "compose.yml", "docker-compose.yaml", "docker-compose.yml",
	]

	static func scan(path: String) -> FolderScan {
		var scan = FolderScan()
		let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty else { return scan }

		let root = URL(fileURLWithPath: trimmed, isDirectory: true)
		scan.path = root.path
		scan.projectName = root.lastPathComponent

		let fileManager = FileManager.default
		for name in composeNames {
			let candidate = root.appendingPathComponent(name)
			if fileManager.fileExists(atPath: candidate.path) {
				scan.composeFiles.append(candidate.path)
			}
		}

		for name in ["Dockerfile", "dockerfile"] {
			let candidate = root.appendingPathComponent(name)
			if fileManager.fileExists(atPath: candidate.path) {
				scan.dockerfiles.append(candidate.path)
				scan.dockerfilePorts = exposedPorts(inDockerfileAt: candidate)
				break
			}
		}

		scan.packageManager = detectPackageManager(root: root, fileManager: fileManager)
		readPackageJSON(root: root, into: &scan)
		return scan
	}

	private static func detectPackageManager(root: URL, fileManager: FileManager) -> String {
		let lockfiles: [(String, String)] = [
			("bun.lock", "bun"), ("bun.lockb", "bun"),
			("pnpm-lock.yaml", "pnpm"),
			("yarn.lock", "yarn"),
			("package-lock.json", "npm"),
		]
		for (file, manager) in lockfiles
			where fileManager.fileExists(atPath: root.appendingPathComponent(file).path)
		{
			return manager
		}
		return "npm"
	}

	private static func readPackageJSON(root: URL, into scan: inout FolderScan) {
		let packageURL = root.appendingPathComponent("package.json")
		guard let data = try? Data(contentsOf: packageURL) else { return }
		guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

		if let name = object["name"] as? String, !name.isEmpty {
			scan.projectName = name.split(separator: "/").last.map(String.init) ?? name
		}
		guard let scripts = object["scripts"] as? [String: Any] else { return }
		scan.scripts = scripts.keys.sorted()

		for candidate in ["dev", "start", "serve"] where scripts[candidate] != nil {
			scan.suggestedScript = candidate
			scan.suggestedCommand = "\(scan.packageManager) run \(candidate)"
			return
		}
	}

	/// Text-parses `EXPOSE` so ports can be prefilled before the image is built.
	private static func exposedPorts(inDockerfileAt url: URL) -> [Int] {
		guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
		var ports: [Int] = []
		for line in text.split(whereSeparator: \.isNewline) {
			let trimmed = line.trimmingCharacters(in: .whitespaces)
			guard trimmed.uppercased().hasPrefix("EXPOSE ") else { continue }
			for token in trimmed.dropFirst("EXPOSE ".count).split(whereSeparator: { $0 == " " || $0 == "\t" }) {
				let value = token.split(separator: "/").first ?? token
				if let port = Int(value), !ports.contains(port) { ports.append(port) }
			}
		}
		return ports.sorted()
	}
}
