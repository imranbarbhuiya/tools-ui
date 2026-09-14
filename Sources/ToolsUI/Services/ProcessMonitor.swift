import Foundation
import Observation
import Darwin

enum ListenerKind: String, Sendable {
	case local = "Local"
	case forwarded = "Forwarded"
	case system = "System"

	var symbol: String {
		switch self {
		case .local: "laptopcomputer"
		case .forwarded: "arrow.left.arrow.right"
		case .system: "gearshape.2"
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

@Observable
@MainActor
final class ProcessMonitor {
	var listeners: [PortListener] = []
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

	private nonisolated static func snapshot(includeSystem: Bool) -> (listeners: [PortListener], total: Int, visible: Int, error: String?) {
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
			return ([], total, visible, "Could not inspect listening ports. \(lsof.output)")
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
		return (unique.sorted { ($0.port, $0.process) < ($1.port, $1.process) }, total, visible, nil)
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
		let forwarders = ["ssh", "kubectl port-forward", "cloudflared", "ngrok", "tailscale", "portless", "frpc", "socat"]
		if forwarders.contains(where: text.contains) { return .forwarded }
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
