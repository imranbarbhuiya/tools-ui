import Darwin
import Foundation
import Observation

struct PortlessRoute: Codable, Hashable, Identifiable, Sendable {
    let hostname: String
    let port: Int
    let pid: Int

    var id: String { hostname }
    var isAlias: Bool { pid == 0 }
}

struct PortlessEntry: Hashable, Identifiable, Sendable {
    let route: PortlessRoute
    let url: String
    let workingDirectory: String
    let command: String
    let isOwnerAlive: Bool
    let listenerPID: Int?

    var id: String { route.id }
    var folderName: String {
        workingDirectory.isEmpty ? "Unknown" : URL(fileURLWithPath: workingDirectory).lastPathComponent
    }
    var status: String {
        if route.isAlias { return "Alias" }
        return isOwnerAlive ? "Running" : "Orphaned"
    }
}

@Observable
@MainActor
final class PortlessMonitor {
    var entries: [PortlessEntry] = []
    var isRefreshing = false
    var isPruning = false
    var error: String?
    var updatedAt: Date?

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        let result = await Task.detached(priority: .userInitiated) { Self.snapshot() }.value
        entries = result.entries
        error = result.error
        updatedAt = Date()
        isRefreshing = false
    }

    func stop(_ entry: PortlessEntry) async {
        guard !entry.route.isAlias else {
            error = "Aliases are not owned by a Portless process."
            return
        }
        let pid = entry.route.pid
        let result = await Task.detached(priority: .userInitiated) { () -> String? in
            guard pid > 1 else { return "Invalid Portless process ID." }
            let command = Self.run("/bin/ps", ["-p", String(pid), "-o", "command="]).output.lowercased()
            guard command.contains("portless") else { return "The route owner has exited or its PID now belongs to another process. Use Prune or refresh." }
            if Darwin.kill(pid_t(pid), SIGTERM) == 0 { return nil }
            return String(cString: strerror(errno))
        }.value
        if let result { error = result; return }
        try? await Task.sleep(for: .milliseconds(500))
        await refresh()
    }

    func removeAlias(_ entry: PortlessEntry) async {
        guard entry.route.isAlias else { return }
        let result = await Task.detached(priority: .userInitiated) {
            guard let executable = Self.portlessExecutable() else { return (127 as Int32, "Portless CLI was not found.") }
            return Self.run(executable, ["alias", "--remove", entry.route.hostname])
        }.value
        if result.0 != 0 { error = result.1; return }
        await refresh()
    }

    func prune() async {
        guard !isPruning else { return }
        isPruning = true
        let result = await Task.detached(priority: .userInitiated) {
            guard let executable = Self.portlessExecutable() else { return (127 as Int32, "Portless CLI was not found.") }
            return Self.run(executable, ["prune"])
        }.value
        isPruning = false
        if result.0 != 0 { error = result.1; return }
        await refresh()
    }

    private nonisolated static func snapshot() -> (entries: [PortlessEntry], error: String?) {
        let statePath = ProcessInfo.processInfo.environment["PORTLESS_STATE_DIR"] ?? NSHomeDirectory() + "/.portless"
        let routesURL = URL(fileURLWithPath: statePath).appendingPathComponent("routes.json")
        guard FileManager.default.fileExists(atPath: routesURL.path) else { return ([], nil) }
        let routes: [PortlessRoute]
        do {
            routes = try JSONDecoder().decode([PortlessRoute].self, from: Data(contentsOf: routesURL))
        } catch {
            return ([], "Could not read Portless routes: \(error.localizedDescription)")
        }
        let stateURL = URL(fileURLWithPath: statePath)
        let proxyPort = Int((try? String(contentsOf: stateURL.appendingPathComponent("proxy.port"), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 443
        let tls = FileManager.default.fileExists(atPath: stateURL.appendingPathComponent("proxy.tls").path)
        let scheme = tls ? "https" : "http"
        let defaultPort = tls ? 443 : 80
        let suffix = proxyPort == defaultPort ? "" : ":\(proxyPort)"
        let entries = routes.map { route in
            let listenerPID = listenerPID(on: route.port)
            let ownerCommand = route.pid > 0 ? run("/bin/ps", ["-p", String(route.pid), "-o", "command="]).output.trimmingCharacters(in: .whitespacesAndNewlines) : ""
            let ownerAlive = route.pid > 0 && ownerCommand.lowercased().contains("portless")
            let directoryPID = ownerAlive ? route.pid : (listenerPID ?? 0)
            let cwd = directoryPID > 0 ? workingDirectory(for: directoryPID) : ""
            return PortlessEntry(route: route, url: "\(scheme)://\(route.hostname)\(suffix)", workingDirectory: cwd, command: ownerCommand, isOwnerAlive: ownerAlive, listenerPID: listenerPID)
        }
        return (entries.sorted { $0.route.hostname < $1.route.hostname }, nil)
    }

    private nonisolated static func listenerPID(on port: Int) -> Int? {
        let output = run("/usr/sbin/lsof", ["-nP", "-t", "-iTCP:\(port)", "-sTCP:LISTEN"]).output
        return output.split(separator: "\n").compactMap { Int($0) }.first
    }

    private nonisolated static func workingDirectory(for pid: Int) -> String {
        let output = run("/usr/sbin/lsof", ["-a", "-p", String(pid), "-d", "cwd", "-Fn"]).output
        return output.split(separator: "\n").first { $0.first == "n" }.map { String($0.dropFirst()) } ?? ""
    }

    private nonisolated static func portlessExecutable() -> String? {
        let candidates = ["/opt/homebrew/bin/portless", "/usr/local/bin/portless"] +
            (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { String($0) + "/portless" }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private nonisolated static func run(_ executable: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (127, error.localizedDescription) }
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()
        return (process.terminationStatus, output)
    }
}
