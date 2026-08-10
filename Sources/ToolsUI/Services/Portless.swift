import AppKit
import Foundation

enum Portless {
	static let defaultTLD = "localhost"
	static let installCommand = "npm install -g portless"
	static let trustCommand = "portless trust"
	static let serviceInstallCommand = "portless service install"
	static let doctorCommand = "portless doctor"
	static let pruneCommand = "portless prune"
	static let proxyStartCommand = "portless proxy start"

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

	/// The positional form pins the hostname to exactly `<name>.localhost`.
	/// `portless run --name` would additionally prepend a git worktree prefix,
	/// which would not match the URL shown in the UI.
	static func wrap(command: String, name: String) -> String {
		"portless \(Shell.quote(name)) \(command)"
	}

	// MARK: - Probe

	/// A snapshot of the local portless install. The proxy port and scheme are
	/// read from live state rather than assumed, because `portless proxy start`
	/// falls back to an unprivileged port (1355) when it cannot bind 443.
	struct Probe: Equatable, Sendable {
		var isInstalled = false
		var proxyPort = 443
		var scheme = "https"
		var proxyIsListening = false
		var routes: [String: String] = [:]

		var isReady: Bool { isInstalled && proxyIsListening }

		var summary: String {
			if !isInstalled { return "Not installed" }
			if !proxyIsListening { return "Proxy not running" }
			return "Ready on \(scheme)://…:\(proxyPort)"
		}

		var hint: String? {
			if !isInstalled {
				return "portless was not found on your PATH. Install it with `\(installCommand)`."
			}
			if !proxyIsListening {
				return "The portless proxy is not listening on port \(proxyPort). Start it from Settings, or run `\(serviceInstallCommand)` in Terminal to have it start at login."
			}
			return nil
		}

		var isDefaultPort: Bool {
			(scheme == "https" && proxyPort == 443) || (scheme == "http" && proxyPort == 80)
		}
	}

	static func probe() async -> Probe {
		var probe = Probe()
		probe.isInstalled = await Shell.run("command -v portless", timeout: 10).isSuccess
		guard probe.isInstalled else { return probe }

		probe.proxyPort = livePort() ?? 443
		probe.scheme = liveScheme() ?? (probe.proxyPort == 80 ? "http" : "https")
		probe.proxyIsListening = Shell.canConnect(port: UInt16(clamping: probe.proxyPort))
		probe.routes = await routes()

		// A registered route is the most reliable statement of what the proxy
		// actually serves, so let it correct the guesses above.
		if let sample = probe.routes.values.first,
		   let components = URLComponents(string: sample),
		   let scheme = components.scheme
		{
			probe.scheme = scheme
			probe.proxyPort = components.port ?? (scheme == "https" ? 443 : 80)
			probe.proxyIsListening = Shell.canConnect(port: UInt16(clamping: probe.proxyPort))
		}
		return probe
	}

	private static func livePort() -> Int? {
		let url = stateDirectory.appendingPathComponent("proxy.port")
		guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
		return Int(text.trimmingCharacters(in: .whitespacesAndNewlines))
	}

	private static func liveScheme() -> String? {
		let url = stateDirectory.appendingPathComponent("proxy.log")
		guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
		if text.contains("HTTPS proxy listening") { return "https" }
		if text.contains("HTTP proxy listening") { return "http" }
		return nil
	}

	/// Parses `portless list`, whose lines look like:
	/// `  http://app.localhost:1355  ->  localhost:8088  (alias)`
	static func routes() async -> [String: String] {
		let result = await Shell.run("portless list", timeout: 15)
		guard result.isSuccess else { return [:] }

		var routes: [String: String] = [:]
		for line in result.output.split(whereSeparator: \.isNewline) {
			let trimmed = line.trimmingCharacters(in: .whitespaces)
			guard trimmed.contains("->") else { continue }
			guard let urlText = trimmed.components(separatedBy: "->").first?.trimmingCharacters(in: .whitespaces) else { continue }
			guard let host = URLComponents(string: urlText)?.host else { continue }
			routes[host] = urlText
		}
		return routes
	}

	static func url(name: String, proxy: Probe?, tld: String = defaultTLD) -> String {
		guard !name.isEmpty else { return "" }
		let hostname = "\(name).\(tld)"
		if let existing = proxy?.routes[hostname] { return existing }

		let scheme = proxy?.scheme ?? "https"
		let port = proxy?.proxyPort ?? 443
		if proxy?.isDefaultPort ?? (port == 443) {
			return "\(scheme)://\(hostname)"
		}
		return "\(scheme)://\(hostname):\(port)"
	}

	// MARK: - Aliases

	/// Static route to an already-listening port. This is how containers get a
	/// name — `portless run` only works for processes portless spawns itself.
	@discardableResult
	static func registerAlias(name: String, port: Int) async -> Shell.Result {
		await Shell.run("portless alias \(Shell.quote(name)) \(port) --force", timeout: 30)
	}

	@discardableResult
	static func removeAlias(name: String) async -> Shell.Result {
		await Shell.run("portless alias --remove \(Shell.quote(name))", timeout: 30)
	}

	@discardableResult
	static func startProxy() async -> Shell.Result {
		await Shell.run(proxyStartCommand, timeout: 60)
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
