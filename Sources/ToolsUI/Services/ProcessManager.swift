import Foundation

final class ProcessManager: @unchecked Sendable {
	enum Event: Sendable {
		case started(pid: Int32)
		case output(String)
		case exited(Int32)
		case failed(String)
	}

	private final class Running: @unchecked Sendable {
		let process: Process
		let id: UUID
		let killGrace: TimeInterval

		init(id: UUID, process: Process, killGrace: TimeInterval) {
			self.id = id
			self.process = process
			self.killGrace = killGrace
		}
	}

	private let lock = NSLock()
	private var running: [UUID: Running] = [:]

	func start(
		service: ManagedService,
		environment: [String: String],
		onEvent: @escaping @Sendable (Event) -> Void
	) {
		run(
			id: service.id,
			command: "exec \(service.launchCommand)",
			cwd: service.workingDirectory,
			environment: environment,
			// Under portless the real dev server is a grandchild, so give the
			// wrapper time to forward SIGTERM and release its route.
			killGrace: service.usesPortless ? 4.0 : 1.2,
			onEvent: onEvent
		)
	}

	/// Also used to tail `docker logs -f`, which is a long-lived child even though
	/// the thing it reports on is the container.
	func run(
		id: UUID,
		command: String,
		cwd: String = "",
		environment: [String: String] = [:],
		killGrace: TimeInterval = 1.2,
		onEvent: @escaping @Sendable (Event) -> Void
	) {
		stop(id: id)

		let process = Process()
		let stdout = Pipe()
		let stderr = Pipe()
		process.standardOutput = stdout
		process.standardError = stderr
		process.standardInput = FileHandle.nullDevice
		process.executableURL = URL(fileURLWithPath: "/bin/zsh")
		process.arguments = ["-lc", command]

		var env = environment.isEmpty ? ProcessInfo.processInfo.environment : environment
		env["TERM"] = "dumb"
		process.environment = env

		let directory = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
		if !directory.isEmpty {
			process.currentDirectoryURL = URL(fileURLWithPath: directory, isDirectory: true)
		}

		let outHandle = stdout.fileHandleForReading
		let errHandle = stderr.fileHandleForReading

		outHandle.readabilityHandler = { handle in
			let data = handle.availableData
			guard !data.isEmpty, let text = String(data: data, encoding: .utf8), !text.isEmpty else { return }
			onEvent(.output(text))
		}
		errHandle.readabilityHandler = { handle in
			let data = handle.availableData
			guard !data.isEmpty, let text = String(data: data, encoding: .utf8), !text.isEmpty else { return }
			onEvent(.output(text))
		}

		process.terminationHandler = { [weak self] proc in
			outHandle.readabilityHandler = nil
			errHandle.readabilityHandler = nil
			self?.lock.lock()
			self?.running[id] = nil
			self?.lock.unlock()
			onEvent(.exited(proc.terminationStatus))
		}

		do {
			try process.run()
			let item = Running(id: id, process: process, killGrace: killGrace)
			lock.lock()
			running[id] = item
			lock.unlock()
			onEvent(.started(pid: process.processIdentifier))
		} catch {
			onEvent(.failed(error.localizedDescription))
		}
	}

	func isRunning(id: UUID) -> Bool {
		lock.lock()
		defer { lock.unlock() }
		return running[id]?.process.isRunning ?? false
	}

	func stop(id: UUID) {
		lock.lock()
		let item = running[id]
		running[id] = nil
		lock.unlock()
		guard let item else { return }

		let process = item.process
		let pid = process.processIdentifier
		if process.isRunning {
			process.terminate()
			DispatchQueue.global().asyncAfter(deadline: .now() + item.killGrace) {
				if process.isRunning {
					kill(pid, SIGKILL)
				}
				Self.killProcessGroup(pid)
			}
		}
		Self.killProcessGroup(pid)
	}

	func stopAll() {
		lock.lock()
		let ids = Array(running.keys)
		lock.unlock()
		for id in ids {
			stop(id: id)
		}
	}

	deinit {
		stopAll()
	}

	private static func killProcessGroup(_ pid: Int32) {
		if pid > 0 {
			kill(-pid, SIGTERM)
		}
	}
}
