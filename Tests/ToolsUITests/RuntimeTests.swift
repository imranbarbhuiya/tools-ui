import Foundation
import Testing
@testable import ToolsUI

@Test func resourceTreesDeduplicateAndIgnoreMissingProcesses() {
	let samples = ResourceUsage.parseProcesses("10 1 0.5 1024\n11 10 75.2 2048\n12 11 125.0 4096\n99 1 10 10\nmalformed\n")
	let tree = ResourceUsage.tree(10, in: samples).union(ResourceUsage.tree(11, in: samples))
	#expect(tree == [10, 11, 12])
	#expect(ResourceUsage.tree(404, in: samples).isEmpty)
	let total = ResourceUsage.total(tree, in: samples)
	#expect(abs(total.cpu - 200.7) < 0.001)
	#expect(total.memory == 7_168 * 1024)
	#expect(total.processCount == 3)
}

@Test func dockerMemoryUnits() {
	#expect(Docker.memoryBytes("2.5MiB") == 2_621_440)
	#expect(Docker.memoryBytes("12.4MB") == 12_400_000)
	#expect(Docker.memoryBytes("1GiB") == 1_073_741_824)
	#expect(Docker.memoryBytes("0B") == 0)
}

@Test @MainActor func checkoutGroupingIncludesExternalServicesAndLiveRoutes() {
	let runtime = RuntimeMonitor()
	let root = "/tmp/project", linked = "/tmp/feature"
	runtime.checkouts[root] = Checkout(directory: root, repository: root, branch: "main", revision: "abc", isLinked: false, changedFiles: 0)
	runtime.checkouts[linked] = Checkout(directory: linked, repository: root, branch: "feat/ui", revision: "abc", isLinked: true, changedFiles: 2)
	let main = ManagedService(name: "Web", workingDirectory: root), feature = ManagedService(name: "Web", workingDirectory: linked)
	runtime.samples = ResourceUsage.parseProcesses("10 1 1 100\n11 10 2 200\n20 1 3 300\n")
	runtime.bind(statuses: [main.id: ServiceStatus(state: .running(pid: 10))])
	runtime.processes.developerProcesses = [
		DeveloperProcess(process: "bun", pid: 11, parentPID: 10, parentProcess: "portless", command: "bun main.ts", workingDirectory: root, elapsed: "00:01", listeningPorts: [4001]),
		DeveloperProcess(process: "bun", pid: 20, parentPID: 1, parentProcess: "launchd", command: "bun main.ts", workingDirectory: linked, elapsed: "00:01", listeningPorts: [4002])]
	runtime.portless.entries = [PortlessEntry(route: PortlessRoute(hostname: "web.localhost", port: 4001, pid: 10), url: "http://web.localhost:1355", workingDirectory: root, command: "portless", isOwnerAlive: true, listenerPID: 11)]
	let groups = runtime.groups(services: [main, feature])
	#expect(groups.count == 2)
	let primary = groups.first { $0.id == Checkout.canonical(root) }
	#expect(primary?.processes.isEmpty == true)
	#expect(primary?.usage.cpu == 3)
	#expect(runtime.route(for: main)?.route.port == 4001)
	#expect(groups.first { $0.checkout?.isLinked == true }?.processes.count == 1)
}

@Test func renameRecordsCountOnce() {
	#expect(Checkout.changedFileCount("R  new file\0old file\0?? added\0 M changed\0") == 3)
}

func temporaryDirectory(_ name: String) throws -> URL {
	let directory = FileManager.default.temporaryDirectory.appendingPathComponent("toolsui-\(name)-\(UUID().uuidString)")
	try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
	return directory
}

@Test func realGitWorktreesAndDetachedHead() async throws {
	let fixture = try temporaryDirectory("git spaces")
	defer { try? FileManager.default.removeItem(at: fixture) }
	let repo = fixture.appendingPathComponent("my repo"), linked = fixture.appendingPathComponent("feature checkout")
	try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
	let command = "git init -b main \(Shell.quote(repo.path)) && git -C \(Shell.quote(repo.path)) -c user.name=ToolsUI -c user.email=test@example.invalid -c commit.gpgsign=false commit --allow-empty -m initial && git -C \(Shell.quote(repo.path)) worktree add -b feat/cockpit \(Shell.quote(linked.path))"
	let result = await Shell.run(command)
	#expect(result.isSuccess)
	let primary = try #require(await Checkout.inspect(repo.path))
	let worktree = try #require(await Checkout.inspect(linked.path))
	#expect(primary.branch == "main")
	#expect(!primary.isLinked)
	#expect(worktree.isLinked)
	#expect(worktree.branch == "feat/cockpit")
	#expect(worktree.repository == primary.repository)
	#expect(worktree.id != primary.id)
	let nested = linked.appendingPathComponent("nested folder")
	try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
	#expect(await Checkout.inspect(nested.path)?.directory == worktree.directory)
	try "changed".write(to: linked.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
	#expect(await Checkout.inspect(linked.path)?.changedFiles == 1)
	let detached = await Shell.run("git checkout --detach", cwd: linked.path)
	#expect(detached.isSuccess)
	let detachedInfo = try #require(await Checkout.inspect(linked.path))
	#expect(detachedInfo.branch.isEmpty)
	#expect(detachedInfo.label.hasPrefix("Detached · "))
}

@Test func unbornRepoAndNonRepo() async throws {
	let fixture = try temporaryDirectory("unborn")
	defer { try? FileManager.default.removeItem(at: fixture) }
	#expect(await Checkout.inspect(fixture.path) == nil)
	let result = await Shell.run("git init -b start", cwd: fixture.path)
	#expect(result.isSuccess)
	let checkout = try #require(await Checkout.inspect(fixture.path))
	#expect(checkout.branch == "start")
	#expect(checkout.revision == "Unborn")
}
