import Foundation

/// One-shot command runner for the CLI probes (docker, portless) the app makes
/// constantly. Long-lived managed processes go through ProcessManager instead.
enum Shell {
	struct Result: Sendable {
		var status: Int32
		var output: String

		var isSuccess: Bool { status == 0 }

		var trimmed: String {
			output.trimmingCharacters(in: .whitespacesAndNewlines)
		}
	}

	static let userPATH: String = enrichedPATH(ProcessInfo.processInfo.environment["PATH"] ?? "")

	static func loginCommand(_ command: String) -> String {
		"export PATH=\(quote(userPATH)):\"$PATH\"; \(command)"
	}

	static func applyUserPATH(to environment: [String: String]) -> [String: String] {
		var env = environment
		env["PATH"] = userPATH
		return env
	}

	/// Runs through a login shell so PATH matches Terminal — docker and portless
	/// often live in version-manager shims (fnm, asdf) that a bare exec misses.
	@discardableResult
	static func run(
		_ command: String,
		cwd: String? = nil,
		timeout: TimeInterval = 20,
		nonInteractive: Bool = true
	) async -> Result {
		await withCheckedContinuation { continuation in
			DispatchQueue.global(qos: .userInitiated).async {
				let process = Process()
				let pipe = Pipe()
				process.executableURL = URL(fileURLWithPath: "/bin/zsh")
				process.arguments = ["-lc", loginCommand(command)]
				process.standardOutput = pipe
				process.standardError = pipe
				process.standardInput = FileHandle.nullDevice

				if let cwd, !cwd.isEmpty {
					process.currentDirectoryURL = URL(fileURLWithPath: cwd, isDirectory: true)
				}

				var env = applyUserPATH(to: ProcessInfo.processInfo.environment)
				if nonInteractive {
					// Without this portless blocks on a sudo TTY prompt the app can
					// never answer; it exits with a readable error instead.
					env["CI"] = "1"
				}
				process.environment = env

				do {
					try process.run()
				} catch {
					continuation.resume(returning: Result(status: 127, output: error.localizedDescription))
					return
				}

				let pid = process.processIdentifier
				let killer = DispatchWorkItem {
					if process.isRunning {
						process.terminate()
						kill(-pid, SIGKILL)
					}
				}
				DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)

				let data = pipe.fileHandleForReading.readDataToEndOfFile()
				process.waitUntilExit()
				killer.cancel()

				continuation.resume(
					returning: Result(
						status: process.terminationStatus,
						output: String(data: data, encoding: .utf8) ?? ""
					)
				)
			}
		}
	}

	/// Same as `run`, but forwards output as it arrives. Used for `docker pull`,
	/// which can take minutes and is unhelpful as a single blob at the end.
	@discardableResult
	static func stream(
		_ command: String,
		cwd: String? = nil,
		timeout: TimeInterval = 900,
		onOutput: @escaping @Sendable (String) -> Void
	) async -> Result {
		await withCheckedContinuation { continuation in
			DispatchQueue.global(qos: .userInitiated).async {
				let process = Process()
				let pipe = Pipe()
				process.executableURL = URL(fileURLWithPath: "/bin/zsh")
				process.arguments = ["-lc", loginCommand(command)]
				process.standardOutput = pipe
				process.standardError = pipe
				process.standardInput = FileHandle.nullDevice

				if let cwd, !cwd.isEmpty {
					process.currentDirectoryURL = URL(fileURLWithPath: cwd, isDirectory: true)
				}
				var env = applyUserPATH(to: ProcessInfo.processInfo.environment)
				env["CI"] = "1"
				env["TERM"] = "dumb"
				process.environment = env

				do {
					try process.run()
				} catch {
					continuation.resume(returning: Result(status: 127, output: error.localizedDescription))
					return
				}

				let pid = process.processIdentifier
				let killer = DispatchWorkItem {
					if process.isRunning {
						process.terminate()
						kill(-pid, SIGKILL)
					}
				}
				DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)

				var collected = ""
				let handle = pipe.fileHandleForReading
				while true {
					let data = handle.availableData
					if data.isEmpty { break }
					if let text = String(data: data, encoding: .utf8), !text.isEmpty {
						collected += text
						onOutput(text)
					}
				}
				process.waitUntilExit()
				killer.cancel()

				continuation.resume(returning: Result(status: process.terminationStatus, output: collected))
			}
		}
	}

	static func quote(_ value: String) -> String {
		"'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
	}

	private static func enrichedPATH(_ base: String) -> String {
		let home = FileManager.default.homeDirectoryForCurrentUser.path
		let extras = [
			"\(home)/.bun/bin",
			"\(home)/.local/bin",
			"\(home)/.cargo/bin",
			"\(home)/.asdf/shims",
			"/opt/homebrew/bin",
			"/opt/homebrew/sbin",
			"/usr/local/bin",
		]
		var parts: [String] = []
		var seen = Set<String>()
		func append(_ item: String) {
			guard !item.isEmpty, !seen.contains(item) else { return }
			seen.insert(item)
			parts.append(item)
		}
		for extra in extras where FileManager.default.fileExists(atPath: extra) {
			append(extra)
		}
		for item in base.split(separator: ":").map(String.init) {
			append(item)
		}
		return parts.joined(separator: ":")
	}

	/// TCP connect probe used for readiness gating.
	static func canConnect(host: String = "127.0.0.1", port: UInt16, timeout: TimeInterval = 1) -> Bool {
		let descriptor = socket(AF_INET, SOCK_STREAM, 0)
		guard descriptor >= 0 else { return false }
		defer { close(descriptor) }

		var address = sockaddr_in()
		address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
		address.sin_family = sa_family_t(AF_INET)
		address.sin_port = port.bigEndian
		address.sin_addr.s_addr = inet_addr(host)

		var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
		setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
		setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

		let result = withUnsafePointer(to: &address) { pointer in
			pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
				connect(descriptor, generic, socklen_t(MemoryLayout<sockaddr_in>.size))
			}
		}
		return result == 0
	}

	static func isPortFree(_ port: Int) -> Bool {
		guard port > 0, port < 65_536 else { return false }
		return !canConnect(port: UInt16(port), timeout: 0.35)
	}

	/// First free port at or after `start`, used when suggesting a host port for a
	/// newly created container.
	static func freePort(from start: Int, avoiding taken: Set<Int> = []) -> Int {
		var candidate = max(1024, start)
		while candidate < 65_535 {
			if !taken.contains(candidate), isPortFree(candidate) { return candidate }
			candidate += 1
		}
		return start
	}
}
