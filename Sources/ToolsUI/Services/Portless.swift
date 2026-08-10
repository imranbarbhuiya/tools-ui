import AppKit
import Foundation

enum Portless {
	static let defaultTLD = "localhost"
	static let proxyPort: UInt16 = 443
	static let installCommand = "npm install -g portless"
	static let trustCommand = "portless trust"
	static let serviceInstallCommand = "portless service install"
	static let doctorCommand = "portless doctor"
	static let pruneCommand = "portless prune"

	static var stateDirectory: URL {
		FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".portless", isDirectory: true)
	}

	/// Reduces a service name to a DNS label portless can serve. Dots survive so
	/// subdomain names like `api.myapp` keep working.
	static func slug(from name: String) -> String {
		var out = ""
		var pendingSeparator = false
		for character in name.lowercased() {
			if character.isASCII, character.isLetter || character.isNumber {
				if pendingSeparator, !out.isEmpty { out.append("-") }
				pendingSeparator = false
				out.append(character)
			} else if character == "." {
				if !out.isEmpty, !out.hasSuffix(".") { out.append(".") }
				pendingSeparator = false
			} else {
				pendingSeparator = true
			}
		}
		while out.hasSuffix("-") || out.hasSuffix(".") { out.removeLast() }
		return out
	}

	static func url(name: String, tld: String = defaultTLD) -> String {
		"https://\(name).\(tld)"
	}

	static func wrap(command: String, name: String) -> String {
		"portless --name \(shellQuote(name)) --force \(command)"
	}

	static func shellQuote(_ value: String) -> String {
		"'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
	}

	struct Health: Equatable, Sendable {
		var isInstalled = false
		var proxyIsListening = false
		var hasState = false

		var isReady: Bool { isInstalled && proxyIsListening }

		var summary: String {
			if !isInstalled { return "Not installed" }
			if !proxyIsListening { return "Proxy not running" }
			return "Ready"
		}

		/// Non-nil whenever a portless service is expected to fail to start.
		var hint: String? {
			if !isInstalled {
				return "portless was not found on your PATH. Install it with `\(installCommand)`."
			}
			if !proxyIsListening {
				return "The portless proxy is not listening on port \(proxyPort). Run `\(serviceInstallCommand)` in Terminal — binding 443 needs sudo, which Tools UI cannot answer."
			}
			return nil
		}
	}

	static func health() async -> Health {
		let installed = await resolvesOnPath()
		let listening = await canConnectToProxy()
		return Health(
			isInstalled: installed,
			proxyIsListening: listening,
			hasState: FileManager.default.fileExists(atPath: stateDirectory.path)
		)
	}

	private static func resolvesOnPath() async -> Bool {
		await run("command -v portless").status == 0
	}

	private static func canConnectToProxy() async -> Bool {
		await withCheckedContinuation { continuation in
			DispatchQueue.global(qos: .userInitiated).async {
				continuation.resume(returning: canConnect(port: proxyPort))
			}
		}
	}

	private static func canConnect(port: UInt16) -> Bool {
		let descriptor = socket(AF_INET, SOCK_STREAM, 0)
		guard descriptor >= 0 else { return false }
		defer { close(descriptor) }

		var address = sockaddr_in()
		address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
		address.sin_family = sa_family_t(AF_INET)
		address.sin_port = port.bigEndian
		address.sin_addr.s_addr = inet_addr("127.0.0.1")

		var timeout = timeval(tv_sec: 1, tv_usec: 0)
		setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

		let result = withUnsafePointer(to: &address) { pointer in
			pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
				connect(descriptor, generic, socklen_t(MemoryLayout<sockaddr_in>.size))
			}
		}
		return result == 0
	}

	@discardableResult
	static func run(_ command: String) async -> (status: Int32, output: String) {
		await withCheckedContinuation { continuation in
			DispatchQueue.global(qos: .userInitiated).async {
				let process = Process()
				let pipe = Pipe()
				process.executableURL = URL(fileURLWithPath: "/bin/zsh")
				process.arguments = ["-lc", command]
				process.standardOutput = pipe
				process.standardError = pipe
				process.standardInput = FileHandle.nullDevice
				do {
					try process.run()
				} catch {
					continuation.resume(returning: (127, error.localizedDescription))
					return
				}
				let data = pipe.fileHandleForReading.readDataToEndOfFile()
				process.waitUntilExit()
				continuation.resume(returning: (process.terminationStatus, String(data: data, encoding: .utf8) ?? ""))
			}
		}
	}

	/// Setup commands need a TTY for their sudo prompt, so hand them to Terminal
	/// instead of running them as a managed process.
	static func openInTerminal(_ command: String) {
		let script = """
		#!/bin/zsh
		\(command)
		echo
		echo 'Finished. You can close this window.'
		"""
		let url = FileManager.default.temporaryDirectory
			.appendingPathComponent("tools-ui-portless-\(UUID().uuidString).command")
		do {
			try script.write(to: url, atomically: true, encoding: .utf8)
			try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
		} catch {
			return
		}
		NSWorkspace.shared.open(url)
	}
}
