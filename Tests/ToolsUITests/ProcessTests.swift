import Foundation
import Testing
@testable import ToolsUI

final class EventCollector: @unchecked Sendable {
	private let lock = NSLock()
	private var values: [ProcessManager.Event] = []
	func append(_ event: ProcessManager.Event) { lock.lock(); values.append(event); lock.unlock() }
	var events: [ProcessManager.Event] { lock.lock(); defer { lock.unlock() }; return values }
	var exited: Bool { events.contains { if case .exited = $0 { return true }; return false } }
	var output: String { events.compactMap { if case let .output(text, _) = $0 { return text }; return nil }.joined() }
}

@Test func processOutputDrainsBeforeExitAndRetainsStreams() async throws {
	let manager = ProcessManager(), capture = EventCollector(), id = UUID()
	manager.run(id: id, command: "printf 'hello 🌍\\n'; printf 'ERROR stderr\\n' >&2; exit 7") { capture.append($0) }
	for _ in 0..<100 where !capture.exited { try await Task.sleep(for: .milliseconds(50)) }
	#expect(capture.exited)
	#expect(capture.output.contains("hello 🌍"))
	#expect(capture.events.contains { if case let .output(text, stream) = $0 { return stream == .stderr && text.contains("ERROR") }; return false })
	#expect(!manager.isRunning(id: id))
	if case let .exited(code) = capture.events.last { #expect(code == 7) } else { Issue.record("Exit must follow all output") }
}

@Test func restartKeepsNewRunnerAndStopsChildren() async throws {
	let manager = ProcessManager(), first = EventCollector(), second = EventCollector(), id = UUID()
	defer { manager.stopAll() }
	manager.run(id: id, command: "sleep 30 & echo child:$!; wait") { first.append($0) }
	for _ in 0..<100 where first.output.range(of: #"child:[0-9]+\n"#, options: .regularExpression) == nil { try await Task.sleep(for: .milliseconds(50)) }
	let range = try #require(first.output.range(of: #"child:[0-9]+"#, options: .regularExpression))
	let child = try #require(Int(first.output[range].dropFirst(6)))
	manager.run(id: id, command: "echo new; exec sleep 30") { second.append($0) }
	try await Task.sleep(for: .milliseconds(600))
	#expect(manager.isRunning(id: id))
	#expect(second.output.contains("new"))
	let check = await Shell.run("ps -p \(child) -o stat=", timeout: 3)
	#expect(!check.isSuccess || check.trimmed.hasPrefix("Z"))
	manager.stop(id: id)
	for _ in 0..<100 where !second.exited { try await Task.sleep(for: .milliseconds(50)) }
	#expect(second.exited)
}

@Suite(.serialized) @MainActor struct ServiceStoreTests {
	@Test func oldConfigurationStillDecodes() throws {
		let json = "{\"id\":\"\(UUID())\",\"name\":\"Old service\",\"command\":\"echo ok\"}"
		let service = try JSONDecoder().decode(ManagedService.self, from: Data(json.utf8))
		#expect(service.kind == .process)
		#expect(service.dependencies.isEmpty)
		#expect(!service.portlessEnabled)
	}

	@Test func dependencyFailureBlocksConsumerAndKeepsDiagnostic() async throws {
		let fixture = try temporaryDirectory("dependency")
		defer { try? FileManager.default.removeItem(at: fixture) }
		let store = ServiceStore(configURL: fixture.appendingPathComponent("services.json"), startAutomatically: false)
		defer { store.shutdown() }
		let dependency = ManagedService(name: "Database", command: "printf 'ERROR connection refused\\n' >&2; exit 7", readiness: ReadinessCheck(mode: .http, url: "http://invalid.localhost", timeout: 5))
		let consumer = ManagedService(name: "API", command: "echo SHOULD_NOT_START", dependencies: [dependency.id])
		store.add(dependency); store.add(consumer)
		store.start(consumer.id)
		for _ in 0..<200 {
			if case .failed = store.status(for: consumer.id).state { break }
			try await Task.sleep(for: .milliseconds(50))
		}
		#expect(store.status(for: consumer.id).label.contains("Database"))
		#expect(!store.status(for: consumer.id).log.contains("SHOULD_NOT_START"))
		#expect(store.logs.entries.contains { $0.serviceID == consumer.id && $0.parsed.level == .error })
		#expect(store.logs.entries.contains { $0.serviceID == dependency.id && $0.stream == .stderr })
	}

	@Test func cancellationAndQuickRestartDoNotReviveStoppedService() async throws {
		let fixture = try temporaryDirectory("cancel")
		defer { try? FileManager.default.removeItem(at: fixture) }
		let store = ServiceStore(configURL: fixture.appendingPathComponent("services.json"), startAutomatically: false)
		defer { store.shutdown() }
		let service = ManagedService(name: "Waiting", command: "exec sleep 30", readiness: ReadinessCheck(mode: .http, url: "http://invalid.localhost", timeout: 5))
		store.add(service); store.start(service.id)
		for _ in 0..<100 where !store.status(for: service.id).isUp { try await Task.sleep(for: .milliseconds(50)) }
		store.stop(service.id)
		try await Task.sleep(for: .milliseconds(900))
		#expect(store.status(for: service.id).state == .stopped)
		#expect(store.lastError == nil)
	}

	@Test func corruptDependencyGraphFailsClearly() async throws {
		let fixture = try temporaryDirectory("graph")
		defer { try? FileManager.default.removeItem(at: fixture) }
		let store = ServiceStore(configURL: fixture.appendingPathComponent("services.json"), startAutomatically: false)
		let service = ManagedService(name: "Broken", command: "echo NO", dependencies: [UUID()])
		store.add(service); store.start(service.id)
		try await Task.sleep(for: .milliseconds(100))
		#expect(store.status(for: service.id).label.contains("missing"))
		store.shutdown()
	}
}

@Test func managedShellSequencesRetainTheirExitCode() async throws {
	let manager = ProcessManager(), capture = EventCollector()
	manager.start(service: ManagedService(name: "Sequence", command: "printf 'ERROR failed\\n' >&2; exit 7"), environment: [:]) { capture.append($0) }
	for _ in 0..<100 where !capture.exited { try await Task.sleep(for: .milliseconds(50)) }
	if case let .exited(code) = capture.events.last { #expect(code == 7) } else { Issue.record("Missing exit status") }
	#expect(capture.output.contains("ERROR failed"))
}
