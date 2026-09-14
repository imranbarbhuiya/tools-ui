import Foundation
import Observation
import Darwin

enum ListenerKind: String, Sendable {
	case local = "Local"
	case usesRemote = "Uses remote"
	case publishesLocal = "Publishes local"
	case forwarded = "Forwarded"
	case system = "System"

	var isForwarded: Bool {
		switch self {
		case .usesRemote, .publishesLocal, .forwarded: true
		case .local, .system: false
		}
	}

	var symbol: String {
		switch self {
		case .local: "laptopcomputer"
		case .usesRemote: "arrow.down.to.line.compact"
		case .publishesLocal: "arrow.up.to.line.compact"
		case .forwarded: "arrow.left.arrow.right"
		case .system: "gearshape.2"
		}
	}

	var explanation: String {
		switch self {
		case .local: "A process listening directly on this Mac"
		case .usesRemote: "Makes a remote service available on this Mac"
		case .publishesLocal: "Exposes a service from this Mac through a tunnel"
		case .forwarded: "Forwarded, but the direction is ambiguous"
		case .system: "A macOS or other-user listener"
		}
	}
}

struct PortListener: Identifiable, Hashable, Sendable {
	var id: String { "\(proto)-\(port)-\(pid)-\(address)" }
	let process: String
	let pid: Int
	let user: String
	let proto: String
	let address: String
	let port: Int
	let kind: ListenerKind
	let command: String
	let parentPID: Int
	let parentProcess: String

	var endpoint: String { "\(address):\(port)" }
}

struct DeveloperProcess: Identifiable, Hashable, Sendable {
	var id: Int { pid }
	let process: String
	let pid: Int
	let parentPID: Int
	let parentProcess: String
	let command: String
	let workingDirectory: String
	let elapsed: String
	let listeningPorts: [Int]
}

@Observable
@MainActor
final class ProcessMonitor {
	var listeners: [PortListener] = []
	var developerProcesses: [DeveloperProcess] = []
	var totalProcessCount = 0
	var visibleProcessCount = 0
	var showSystem = false
	var isRefreshing = false
	var error: String?
	var updatedAt: Date?

	var displayedListeners: [PortListener] {
		showSystem ? listeners : listeners.filter { $0.kind != .system }
	}

	func refresh() async {
		guard !isRefreshing else { return }
		isRefreshing = true
		let includeSystem = showSystem
		let snapshot = await Task.detached(priority: .userInitiated) {
			Self.snapshot(includeSystem: includeSystem)
		}.value
		listeners = snapshot.listeners
		developerProcesses = snapshot.developerProcesses
		totalProcessCount = snapshot.total
		visibleProcessCount = snapshot.visible
		error = snapshot.error
		updatedAt = Date()
		isRefreshing = false
	}

	func terminate(_ listener: PortListener) async {
		guard listener.pid > 1, listener.kind != .system else {
			error = "This process cannot be terminated from Process Finder."
			return
		}

		let result = await Task.detached(priority: .userInitiated) {
			if Darwin.kill(pid_t(listener.pid), SIGTERM) == 0 { return nil as String? }
			return String(cString: strerror(errno))
		}.value

		if let result {
			error = "Could not terminate \(listener.process) (PID \(listener.pid)): \(result)"
			return
		}

		try? await Task.sleep(for: .milliseconds(500))
		await refresh()
	}

	func terminate(_ process: DeveloperProcess) async {
		guard process.pid > 1 else {
			error = "This process cannot be terminated from Process Finder."
			return
		}
		await terminate(pid: process.pid, name: process.process)
	}

	private func terminate(pid: Int, name: String) async {
		let result = await Task.detached(priority: .userInitiated) {
			if Darwin.kill(pid_t(pid), SIGTERM) == 0 { return nil as String? }
			return String(cString: strerror(errno))
		}.value

		if let result {
			error = "Could not terminate \(name) (PID \(pid)): \(result)"
			return
		}
		try? await Task.sleep(for: .milliseconds(500))
		await refresh()
	}

	private nonisolated static func snapshot(includeSystem: Bool) -> (listeners: [PortListener], developerProcesses: [DeveloperProcess], total: Int, visible: Int, error: String?) {
		let uid = getuid()
		let user = NSUserName()
		let processes = run("/bin/ps", ["-axo", "pid=,uid=,comm="])
		let processLines = processes.output.split(separator: "\n")
		let total = processLines.count
		let visible = processLines.filter { line in
			let pieces = line.split(maxSplits: 2, whereSeparator: \Character.isWhitespace)
			guard pieces.count > 2, UInt32(pieces[1]) == uid else { return false }
			return !isSystemCommand(String(pieces[2]))
		}.count

		let lsof = run("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-FpcuPnT"])
		guard lsof.status == 0 || !lsof.output.isEmpty else {
			return ([], [], total, visible, "Could not inspect listening ports. \(lsof.output)")
		}

		var result: [PortListener] = []
		var pid = 0
		var process = "Unknown"
		var ownerUID: UInt32 = UInt32.max
		var command = ""
		var parentPID = 0
		var parentProcess = ""

		for raw in lsof.output.split(separator: "\n") {
			guard let prefix = raw.first else { continue }
			let value = String(raw.dropFirst())
			switch prefix {
			case "p":
				pid = Int(value) ?? 0
				command = commandForPID(pid)
				(parentPID, parentProcess) = parentDetails(for: pid)
			case "c": process = value
			case "u": ownerUID = UInt32(value) ?? UInt32.max
			case "n":
				guard let parsed = parseEndpoint(value) else { continue }
				let kind = classify(process: process, command: command, ownerUID: ownerUID, currentUID: uid)
				let owner = ownerUID == uid ? user : "UID \(ownerUID)"
				if includeSystem || kind != .system {
					result.append(PortListener(process: process, pid: pid, user: owner, proto: "TCP", address: parsed.address, port: parsed.port, kind: kind, command: command, parentPID: parentPID, parentProcess: parentProcess))
				}
			default: break
			}
		}

		let unique = Dictionary(grouping: result, by: \.id).compactMap(\.value.first)
		let sortedListeners = unique.sorted { ($0.port, $0.process) < ($1.port, $1.process) }
		let developerProcesses = developerProcessSnapshot(uid: uid, listeners: sortedListeners)
		return (sortedListeners, developerProcesses, total, visible, nil)
	}

	private nonisolated static func developerProcessSnapshot(uid: UInt32, listeners: [PortListener]) -> [DeveloperProcess] {
		let output = run("/bin/ps", ["-ww", "-axo", "pid=,ppid=,uid=,etime=,comm="]).output
		let runtimes: Set<String> = [
			"node", "bun", "deno", "python", "python3", "ruby", "java", "tsx", "ts-node",
			"npm", "npx", "pnpm", "yarn", "php", "uvicorn", "gunicorn", "dotnet", "air",
		]
		let wrapperNames: Set<String> = ["npm", "npx", "pnpm", "yarn"]
		let home = NSHomeDirectory()
		let portsByPID = Dictionary(grouping: listeners, by: \.pid)
		var candidates: [DeveloperProcess] = []

		for line in output.split(separator: "\n") {
			let pieces = line.split(maxSplits: 4, whereSeparator: \Character.isWhitespace)
			guard pieces.count == 5,
				let pid = Int(pieces[0]),
				Int(pieces[1]) != nil,
				UInt32(pieces[2]) == uid
			else { continue }

			let executable = String(pieces[4])
			let name = URL(fileURLWithPath: executable).lastPathComponent
			guard runtimes.contains(name) || executable.hasPrefix(home + "/") else { continue }
			guard !isSystemCommand(executable), name != "ToolsUI", name != "ProcessFinder" else { continue }

			let cwd = workingDirectory(for: pid)
			let command = commandForPID(pid)
			guard isDeveloperDirectory(cwd, home: home) || command.contains(home + "/Documents/") || command.contains(home + "/Projects/") else { continue }
			let parent = parentDetails(for: pid)
			guard !isDeveloperToolingNoise(name: name, command: command, parent: parent.1) else { continue }
			let ports = Array(Set(portsByPID[pid, default: []].map(\.port))).sorted()
			candidates.append(DeveloperProcess(
				process: name,
				pid: pid,
				parentPID: parent.0,
				parentProcess: parent.1,
				command: command,
				workingDirectory: cwd,
				elapsed: String(pieces[3]),
				listeningPorts: ports
			))
		}

		let parentIDs = Set(candidates.map(\.parentPID))
		return candidates
			.filter {
				let isWrapper = wrapperNames.contains($0.process) || isPackageManagerWrapper($0.command)
				return !isWrapper || !parentIDs.contains($0.pid)
			}
			.sorted { ($0.process.lowercased(), $0.pid) < ($1.process.lowercased(), $1.pid) }
	}

	private nonisolated static func isPackageManagerWrapper(_ command: String) -> Bool {
		let text = command.lowercased()
		return text.contains("/yarn") || text.contains("/npm-cli.js") || text.contains("/pnpm")
	}

	private nonisolated static func isDeveloperToolingNoise(name: String, command: String, parent: String) -> Bool {
		let text = "\(name) \(command) \(parent)".lowercased()
		let markers = [
			"/applications/chatgpt.app/",
			"cua-repl",
			"artifact-template-picker",
			"trusted-worker.js",
			"kernel.js --session-id",
			"chrome-native-host",
			"agent-device/dist/src/internal/daemon",
			"rust-analyzer",
			" --lsp",
			"cursor helper (plugin)",
		]
		return markers.contains(where: text.contains)
	}

	private nonisolated static func workingDirectory(for pid: Int) -> String {
		let output = run("/usr/sbin/lsof", ["-a", "-p", String(pid), "-d", "cwd", "-Fn"]).output
		return output.split(separator: "\n")
			.first { $0.first == "n" }
			.map { String($0.dropFirst()) } ?? ""
	}

	private nonisolated static func isDeveloperDirectory(_ directory: String, home: String) -> Bool {
		guard directory.hasPrefix(home + "/") else { return false }
		let relative = directory.dropFirst(home.count + 1)
		let excluded = ["Library/", "Applications/", ".local/", ".config/", ".cache/"]
		return !excluded.contains { relative.hasPrefix($0) }
	}

	private nonisolated static func parseEndpoint(_ value: String) -> (address: String, port: Int)? {
		let endpoint = value.components(separatedBy: "->").first ?? value
		guard let colon = endpoint.lastIndex(of: ":"), let port = Int(endpoint[endpoint.index(after: colon)...]) else { return nil }
		var address = String(endpoint[..<colon])
		if address.hasPrefix("[") && address.hasSuffix("]") { address = String(address.dropFirst().dropLast()) }
		return (address.isEmpty ? "*" : address, port)
	}

	private nonisolated static func classify(process: String, command: String, ownerUID: UInt32, currentUID: UInt32) -> ListenerKind {
		let text = "\(process) \(command)".lowercased()
		if text.contains("kubectl port-forward") { return .usesRemote }
		if text.contains("ssh"), text.contains(" -l") || text.contains(" -d") { return .usesRemote }
		if text.contains("ssh"), text.contains(" -r") { return .publishesLocal }

		let publishers = ["cloudflared", "ngrok", "frpc", "tailscale funnel", "tailscale serve"]
		if publishers.contains(where: text.contains) { return .publishesLocal }

		let ambiguousForwarders = ["ssh", "portless", "socat"]
		if ambiguousForwarders.contains(where: text.contains) { return .forwarded }
		return ownerUID == currentUID && !isSystemCommand(command) ? .local : .system
	}

	private nonisolated static func isSystemCommand(_ command: String) -> Bool {
		let path = command.trimmingCharacters(in: .whitespacesAndNewlines)
		return ["/System/", "/usr/libexec/", "/usr/sbin/", "/Library/Apple/System/"].contains { path.hasPrefix($0) }
	}

	private nonisolated static func commandForPID(_ pid: Int) -> String {
		guard pid > 0 else { return "" }
		let command = run("/bin/ps", ["-p", String(pid), "-o", "command="])
			.output.trimmingCharacters(in: .whitespacesAndNewlines)
		let executable = run("/bin/ps", ["-ww", "-p", String(pid), "-o", "comm="])
			.output.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !executable.isEmpty else { return command }

		let name = URL(fileURLWithPath: executable).lastPathComponent
		if command == executable { return name }
		if command.hasPrefix(executable + " ") {
			return name + command.dropFirst(executable.count)
		}
		return command
	}

	private nonisolated static func parentDetails(for pid: Int) -> (Int, String) {
		guard pid > 1 else { return (0, "") }
		let parentText = run("/bin/ps", ["-p", String(pid), "-o", "ppid="])
			.output.trimmingCharacters(in: .whitespacesAndNewlines)
		guard let parentPID = Int(parentText), parentPID > 1 else { return (0, "") }

		let executable = run("/bin/ps", ["-ww", "-p", String(parentPID), "-o", "comm="])
			.output.trimmingCharacters(in: .whitespacesAndNewlines)
		let name = URL(fileURLWithPath: executable).lastPathComponent
		guard !name.isEmpty, name != "launchd" else { return (0, "") }
		return (parentPID, name)
	}

	private nonisolated static func run(_ executable: String, _ arguments: [String]) -> (status: Int32, output: String) {
		let process = Process()
		let pipe = Pipe()
		process.executableURL = URL(fileURLWithPath: executable)
		process.arguments = arguments
		process.standardOutput = pipe
		process.standardError = pipe
		do { try process.run() } catch { return (127, error.localizedDescription) }
		let data = pipe.fileHandleForReading.readDataToEndOfFile()
		process.waitUntilExit()
		return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
	}
}
