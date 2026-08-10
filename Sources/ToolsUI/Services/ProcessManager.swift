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

	func start(service: ManagedService, onEvent: @escaping @Sendable (Event) -> Void) {
		stop(id: service.id)

		let process = Process()
		let stdout = Pipe()
		let stderr = Pipe()
		process.standardOutput = stdout
		process.standardError = stderr
		process.standardInput = FileHandle.nullDevice
		process.executableURL = URL(fileURLWithPath: "/bin/zsh")
		process.arguments = ["-lc", "exec \(service.launchCommand)"]

		var env = ProcessInfo.processInfo.environment
		env["TERM"] = "dumb"
		process.environment = env

		let cwd = service.workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
		if !cwd.isEmpty {
			process.currentDirectoryURL = URL(fileURLWithPath: cwd, isDirectory: true)
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
			self?.running[service.id] = nil
			self?.lock.unlock()
			onEvent(.exited(proc.terminationStatus))
		}

		do {
			try process.run()
			// Under portless the real dev server is a grandchild, so give the
			// wrapper time to forward SIGTERM and release its route.
			let item = Running(
				id: service.id,
				process: process,
				killGrace: service.usesPortless ? 4.0 : 1.2
			)
			lock.lock()
			running[service.id] = item
			lock.unlock()
			onEvent(.started(pid: process.processIdentifier))
		} catch {
			onEvent(.failed(error.localizedDescription))
		}
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
