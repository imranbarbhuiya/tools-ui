import Foundation

struct UTF8StreamDecoder {
	private var pending = Data()

	mutating func append(_ data: Data, final: Bool = false) -> String {
		pending.append(data)
		var end = pending.count
		if !final, end > 0 {
			let bytes = Array(pending.suffix(4))
			var index = bytes.count - 1
			while index > 0, bytes[index] & 0xC0 == 0x80 { index -= 1 }
			let lead = bytes[index]
			let length = lead & 0xF8 == 0xF0 ? 4 : lead & 0xF0 == 0xE0 ? 3 : lead & 0xE0 == 0xC0 ? 2 : 1
			if bytes.count - index < length { end -= bytes.count - index }
		}
		let text = String(decoding: pending.prefix(end), as: UTF8.self)
		pending.removeFirst(end)
		return text
	}
}

final class ProcessManager: @unchecked Sendable {
	enum Event: Sendable {
		case started(pid: Int32)
		case output(String, stream: LogStream)
		case exited(Int32)
		case failed(String)
	}

	private struct Running {
		let process: Process
		let killGrace: TimeInterval
	}

	private let lock = NSLock()
	private let events = DispatchQueue(label: "dev.toolsui.process-events")
	private var running: [UUID: Running] = [:]

	func start(service: ManagedService, environment: [String: String], onEvent: @escaping @Sendable (Event) -> Void) {
		run(id: service.id, command: service.launchCommand, cwd: service.workingDirectory,
			environment: environment, killGrace: service.usesPortless ? 4 : 1.2, onEvent: onEvent)
	}

	func run(id: UUID, command: String, cwd: String = "", environment: [String: String] = [:],
		killGrace: TimeInterval = 1.2, onEvent: @escaping @Sendable (Event) -> Void) {
		stop(id: id)
		let process = Process()
		let stdout = Pipe(), stderr = Pipe()
		process.standardOutput = stdout
		process.standardError = stderr
		process.standardInput = FileHandle.nullDevice
		process.executableURL = URL(fileURLWithPath: "/bin/zsh")
		process.arguments = ["-lc", Shell.loginCommand(command)]
		var env = Shell.applyUserPATH(to: environment.isEmpty ? ProcessInfo.processInfo.environment : environment)
		env["TERM"] = "dumb"
		if command.hasPrefix("portless run ") { env["CI"] = "1" }
		process.environment = env
		if !cwd.isEmpty { process.currentDirectoryURL = URL(fileURLWithPath: (cwd as NSString).expandingTildeInPath) }

		let readers = DispatchGroup()
		readers.enter()
		readers.enter()
		let events = events
		process.terminationHandler = { [weak self] proc in
			self?.remove(id: id, process: proc)
			readers.notify(queue: events) { onEvent(.exited(proc.terminationStatus)) }
		}
		lock.lock()
		running[id] = Running(process: process, killGrace: killGrace)
		lock.unlock()
		do {
			try process.run()
			events.async { onEvent(.started(pid: process.processIdentifier)) }
			for (pipe, stream) in [(stdout, LogStream.stdout), (stderr, LogStream.stderr)] {
				DispatchQueue.global(qos: .utility).async {
					var decoder = UTF8StreamDecoder()
					while true {
						let data = pipe.fileHandleForReading.availableData
						if data.isEmpty { break }
						let text = decoder.append(data)
						if !text.isEmpty { events.async { onEvent(.output(text, stream: stream)) } }
					}
					let tail = decoder.append(Data(), final: true)
					if !tail.isEmpty { events.async { onEvent(.output(tail, stream: stream)) } }
					try? pipe.fileHandleForReading.close()
					readers.leave()
				}
			}
		} catch {
			remove(id: id, process: process)
			readers.leave()
			readers.leave()
			let message = error.localizedDescription
			events.async { onEvent(.failed(message)) }
		}
	}

	private func remove(id: UUID, process: Process) {
		lock.lock()
		if running[id]?.process === process { running[id] = nil }
		lock.unlock()
	}

	func isRunning(id: UUID) -> Bool {
		lock.lock()
		defer { lock.unlock() }
		return running[id]?.process.isRunning ?? false
	}

	func stop(id: UUID) {
		lock.lock()
		let item = running.removeValue(forKey: id)
		lock.unlock()
		guard let item, item.process.isRunning else { return }
		let process = item.process
		let pid = process.processIdentifier
		// Snapshot descendants before the wrapper can exit and orphan them.
		let descendants = Self.descendants(of: Int(pid))
		for child in descendants { kill(Int32(child), SIGTERM) }
		process.terminate()
		DispatchQueue.global().asyncAfter(deadline: .now() + item.killGrace) {
			guard process.isRunning else { return }
			for child in Self.descendants(of: Int(pid)) { kill(Int32(child), SIGKILL) }
			kill(pid, SIGKILL)
		}
	}

	private static func descendants(of pid: Int) -> Set<Int> {
		let process = Process(), pipe = Pipe()
		process.executableURL = URL(fileURLWithPath: "/bin/ps")
		process.arguments = ["-axo", "pid=,ppid=,%cpu=,rss="]
		process.environment = ["LC_ALL": "C"]
		process.standardOutput = pipe
		process.standardError = FileHandle.nullDevice
		guard (try? process.run()) != nil else { return [] }
		let data = pipe.fileHandleForReading.readDataToEndOfFile()
		process.waitUntilExit()
		return ResourceUsage.tree(pid, in: ResourceUsage.parseProcesses(String(decoding: data, as: UTF8.self))).subtracting([pid])
	}

	func stopAll() {
		lock.lock()
		let ids = Array(running.keys)
		lock.unlock()
		for id in ids { stop(id: id) }
	}

	deinit { stopAll() }
}
