import Foundation
import Observation

struct ProcessUsage: Equatable, Sendable {
	let pid: Int
	let parentPID: Int
	let cpu: Double
	let memory: Int64
}

struct ResourceUsage: Equatable, Sendable {
	var cpu: Double = 0
	var memory: Int64 = 0
	var processCount: Int = 0
	var cpuText: String { String(format: "%.1f%%", cpu) }
	var memoryText: String { ByteCountFormatter.string(fromByteCount: memory, countStyle: .memory) }

	static func parseProcesses(_ output: String) -> [Int: ProcessUsage] {
		var result: [Int: ProcessUsage] = [:]
		for line in output.split(separator: "\n") {
			let parts = line.split(whereSeparator: \.isWhitespace)
			guard parts.count == 4, let pid = Int(parts[0]), let parent = Int(parts[1]),
				let cpu = Double(parts[2]), let rss = Int64(parts[3]) else { continue }
			result[pid] = ProcessUsage(pid: pid, parentPID: parent, cpu: cpu, memory: rss * 1024)
		}
		return result
	}

	static func tree(_ root: Int, in processes: [Int: ProcessUsage]) -> Set<Int> {
		guard processes[root] != nil else { return [] }
		let children = Dictionary(grouping: processes.values, by: \.parentPID)
		var found: Set<Int> = [root]
		var queue = [root]
		while let current = queue.popLast() {
			for child in children[current, default: []] where found.insert(child.pid).inserted {
				queue.append(child.pid)
			}
		}
		return found
	}

	static func total(_ pids: Set<Int>, in processes: [Int: ProcessUsage]) -> ResourceUsage {
		pids.reduce(into: ResourceUsage()) { result, pid in
			guard let usage = processes[pid] else { return }
			result.cpu += usage.cpu
			result.memory += usage.memory
			result.processCount += 1
		}
	}
}

struct CheckoutGroup: Identifiable {
	let id: String
	let checkout: Checkout?
	let services: [ManagedService]
	let processes: [DeveloperProcess]
	let routes: [PortlessEntry]
	let usage: ResourceUsage
	var name: String { checkout?.name ?? (id.isEmpty ? "Other services" : URL(fileURLWithPath: id).lastPathComponent) }
	var branch: String { checkout?.label ?? "Folder" }
}

@Observable
@MainActor
final class RuntimeMonitor {
	let processes = ProcessMonitor()
	let portless = PortlessMonitor()
	var checkouts: [String: Checkout] = [:]
	var samples: [Int: ProcessUsage] = [:]
	var servicePIDs: [UUID: Set<Int>] = [:]
	var containerUsage: [UUID: ResourceUsage] = [:]
	var expectedURLs: [UUID: String] = [:]
	var updatedAt: Date?
	var error: String?
	var isRefreshing = false
	private var lastCheckoutRefresh = Date.distantPast
	private var scannedDirectories: Set<String> = []

	func refresh(services: [ManagedService], statuses: [UUID: ServiceStatus], containers: [UUID: String]) async {
		if isRefreshing {
			while isRefreshing, !Task.isCancelled { try? await Task.sleep(for: .milliseconds(50)) }
			return
		}
		if Task.isCancelled { return }
		isRefreshing = true
		defer { isRefreshing = false }
		async let ports: Void = portless.refresh()
		async let processList: Void = processes.refresh()
		async let metrics = Shell.run("LC_ALL=C /bin/ps -axo pid=,ppid=,%cpu=,rss=", timeout: 5)
		async let docker = Docker.resourceUsage(containers: containers)
		await ports
		await processList
		let result = await metrics
		if result.isSuccess { samples = ResourceUsage.parseProcesses(result.output) }
		error = result.isSuccess ? processes.error ?? portless.error : "Could not sample process resources: \(result.trimmed)"
		containerUsage = await docker
		bind(statuses: statuses)
		let directories = Set((services.map(\.projectDirectory) + processes.developerProcesses.map(\.workingDirectory) + portless.entries.map(\.workingDirectory))
			.filter { !$0.isEmpty }.map(Checkout.canonical))
		if directories != scannedDirectories || Date().timeIntervalSince(lastCheckoutRefresh) >= 10 {
			var next: [String: Checkout] = [:]
			for directory in directories.sorted() {
				if let checkout = await Checkout.inspect(directory) {
					next[directory] = checkout
				}
			}
			checkouts = next
			scannedDirectories = directories
			lastCheckoutRefresh = Date()
			let ids = Set(services.map(\.id))
			var urls = expectedURLs.filter { ids.contains($0.key) }
			for service in services where service.usesPortless {
				let result = await Shell.run("portless get \(Shell.quote(service.resolvedPortlessName))\(service.isDocker ? " --no-worktree" : "")", cwd: service.projectDirectory, timeout: 5)
				if result.isSuccess, let url = URL(string: result.trimmed), ["http", "https"].contains(url.scheme) {
					urls[service.id] = result.trimmed
				}
			}
			expectedURLs = urls
		}
		updatedAt = Date()
	}

	func bind(statuses: [UUID: ServiceStatus]) {
		servicePIDs = Dictionary(uniqueKeysWithValues: statuses.map { id, status in
			let pid: Int = if case let .running(value) = status.state { Int(value) } else { 0 }
			return (id, ResourceUsage.tree(pid, in: samples))
		})
	}

	func invalidate() { lastCheckoutRefresh = .distantPast }

	func checkout(for directory: String) -> Checkout? {
		let path = Checkout.canonical(directory)
		return checkouts[path] ?? checkouts.values.filter { Checkout.contains(path, in: $0.directory) }.max { $0.directory.count < $1.directory.count }
	}

	func route(for service: ManagedService) -> PortlessEntry? {
		let owned = servicePIDs[service.id, default: []]
		if let route = portless.entries.first(where: { !$0.route.isAlias && owned.contains($0.route.pid) }) { return route }
		guard let host = URL(string: expectedURLs[service.id] ?? "")?.host else { return nil }
		return portless.entries.first { $0.route.hostname == host }
	}

	func usage(for service: ManagedService) -> ResourceUsage? {
		if service.isDocker { return containerUsage[service.id] }
		let pids = servicePIDs[service.id, default: []]
		return pids.isEmpty ? nil : ResourceUsage.total(pids, in: samples)
	}

	func groups(services: [ManagedService]) -> [CheckoutGroup] {
		let managedPIDs = servicePIDs.values.reduce(into: Set<Int>()) { $0.formUnion($1) }
		let candidates = processes.developerProcesses.filter { process in
			guard !managedPIDs.contains(process.pid), samples[process.pid] != nil else { return false }
			let directory = Checkout.canonical(process.workingDirectory)
			return !directory.isEmpty && directory != "/" && (!directory.contains("/.codex/") || directory.contains("/.codex/worktrees/"))
				&& !directory.contains("/.agents/") && !process.command.contains("typingsInstaller.js")
				&& !process.command.contains("/typescript/lib/")
		}
		let candidateIDs = Set(candidates.map(\.pid))
		let external = candidates.filter { process in
			var parent = process.parentPID
			var seen: Set<Int> = [process.pid]
			while parent > 1, seen.insert(parent).inserted {
				if candidateIDs.contains(parent) { return false }
				parent = samples[parent]?.parentPID ?? 0
			}
			return true
		}
		var members: [String: [ManagedService]] = [:]
		var processesByDirectory: [String: [DeveloperProcess]] = [:]
		var routesByDirectory: [String: [PortlessEntry]] = [:]
		for service in services {
			let path = Checkout.canonical(service.projectDirectory)
			members[checkout(for: path)?.id ?? path, default: []].append(service)
		}
		for process in external {
			let path = Checkout.canonical(process.workingDirectory)
			processesByDirectory[checkout(for: path)?.id ?? path, default: []].append(process)
		}
		for route in portless.entries {
			let path = Checkout.canonical(route.workingDirectory)
			routesByDirectory[checkout(for: path)?.id ?? path, default: []].append(route)
		}
		let keys = Set(members.keys).union(processesByDirectory.keys).union(routesByDirectory.keys)
		return keys.map { key in
			let services = members[key, default: []]
			let processes = processesByDirectory[key, default: []]
			let routes = routesByDirectory[key, default: []]
			var pids = services.reduce(into: Set<Int>()) { $0.formUnion(servicePIDs[$1.id, default: []]) }
			for process in processes { pids.formUnion(ResourceUsage.tree(process.pid, in: samples)) }
			for route in routes { pids.formUnion(ResourceUsage.tree(route.route.pid, in: samples)) }
			var usage = ResourceUsage.total(pids, in: samples)
			for service in services where service.isDocker {
				if let sample = containerUsage[service.id] { usage.cpu += sample.cpu; usage.memory += sample.memory }
			}
			return CheckoutGroup(id: key, checkout: checkout(for: key), services: services, processes: processes, routes: routes, usage: usage)
		}.sorted { ($0.name.localizedLowercase, $0.branch, $0.id) < ($1.name.localizedLowercase, $1.branch, $1.id) }
	}
}
