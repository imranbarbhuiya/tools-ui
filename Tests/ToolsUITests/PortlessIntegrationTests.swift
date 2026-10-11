import Foundation
import Testing
@testable import ToolsUI

@Test(.enabled(if: ProcessInfo.processInfo.environment["TOOLSUI_HTTP_INTEGRATION"] == "1"))
@MainActor func realPortlessWorktreesAndDependencyEnvironment() async throws {
	let fixture = try temporaryDirectory("http integration")
	defer { try? FileManager.default.removeItem(at: fixture) }
	let main = fixture.appendingPathComponent("main"), linked = fixture.appendingPathComponent("feature")
	try FileManager.default.createDirectory(at: main, withIntermediateDirectories: true)
	try #"const server = Bun.serve({hostname:'127.0.0.1', port:Number(process.env.PORT), fetch(){return new Response('ready')}}); console.log(JSON.stringify({level:30,msg:'ready',port:server.port}));"#
		.write(to: main.appendingPathComponent("server.js"), atomically: true, encoding: .utf8)
	let git = await Shell.run("git init -b main && git add server.js && git -c user.name=ToolsUI -c user.email=test@example.invalid -c commit.gpgsign=false commit -m initial && git worktree add -b feat/cockpit \(Shell.quote(linked.path))", cwd: main.path)
	#expect(git.isSuccess)
	let store = ServiceStore(configURL: fixture.appendingPathComponent("services.json"), startAutomatically: false)
	defer { store.shutdown() }
	let name = "toolsui-integration-" + UUID().uuidString.prefix(8).lowercased()
	let web = ManagedService(name: "Primary", workingDirectory: main.path, command: "bun server.js", portlessEnabled: true, portlessName: name, providedEnv: [EnvEntry(key: "API_URL", value: "{{url}}")], readiness: ReadinessCheck(timeout: 10))
	let feature = ManagedService(name: "Feature", workingDirectory: linked.path, command: "bun server.js", portlessEnabled: true, portlessName: name, providedEnv: [EnvEntry(key: "API_URL", value: "{{url}}")], readiness: ReadinessCheck(mode: .tcpPort, port: 1, timeout: 10))
	let consumer = ManagedService(name: "Consumer", command: "printf 'URL=%s\\n' \"$API_URL\"", dependencies: [feature.id])
	store.add(web); store.add(feature); store.add(consumer)
	store.start(web.id); store.start(consumer.id)
	for _ in 0..<300 {
		if store.status(for: consumer.id).log.contains("URL=http") { break }
		try await Task.sleep(for: .milliseconds(50))
	}
	await store.refreshRuntime()
	let primaryURL = store.effectiveURL(for: web), featureURL = store.effectiveURL(for: feature)
	#expect(primaryURL != featureURL)
	#expect(featureURL.contains("cockpit."))
	#expect(primaryURL.hasPrefix("http://"))
	#expect(store.status(for: consumer.id).log.contains("URL=" + featureURL))
	#expect(store.runtime.route(for: web) != nil)
	#expect(store.runtime.route(for: feature) != nil)
	#expect(store.runtime.usage(for: feature)?.processCount ?? 0 >= 2)
	#expect(store.logs.entries.contains { $0.serviceID == feature.id && $0.parsed.message == "ready" })
	let response = await Shell.run("/usr/bin/curl --noproxy '*' --fail --silent \(Shell.quote(featureURL))", timeout: 5)
	#expect(response.trimmed == "ready")
	store.stopAll()
	try await Task.sleep(for: .seconds(1))
	await store.refreshRuntime()
	#expect(store.runtime.portless.entries.allSatisfy { !$0.route.hostname.contains(name) })
}
