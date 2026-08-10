import AppKit
import Foundation
import Observation

struct ResolvedEnvVar: Identifiable, Equatable {
	var id: String { key }
	var key: String
	var value: String
	var source: String
	var isOverride: Bool
}

@Observable
@MainActor
final class ServiceStore {
	var services: [ManagedService] = []
	var statuses: [UUID: ServiceStatus] = [:]
	var lastError: String?

	var portless: Portless.Probe?
	var dockerAvailability: DockerAvailability?
	var dockerContainers: [DockerContainer] = []
	var isRefreshingDocker = false

	private let runners = ProcessManager()
	/// `docker logs -f` children. Kept apart from `runners` so their exit does not
	/// read as the service itself dying.
	private let logStreamers = ProcessManager()
	private var startTasks: [UUID: Task<Void, Never>] = [:]
	/// `docker stop` takes seconds to return. Without this the status poll would
	/// see the container still up and flip the row back to Running mid-stop.
	private var stoppingIDs: Set<UUID> = []
	private let saveURL: URL

	init() {
		let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
			.appendingPathComponent("ToolsUI", isDirectory: true)
		try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		saveURL = dir.appendingPathComponent("services.json")
		load()
		if services.isEmpty {
			services = Self.seed
			save()
		}
		for service in services {
			statuses[service.id] = ServiceStatus()
		}
		Task { [weak self] in
			await self?.refreshAll()
			await self?.startAutoStartServices()
		}
	}

	// MARK: - Lookup

	func find(_ id: UUID) -> ManagedService? {
		services.first { $0.id == id }
	}

	func status(for id: UUID) -> ServiceStatus {
		statuses[id] ?? ServiceStatus()
	}

	func container(named name: String) -> DockerContainer? {
		guard !name.isEmpty else { return nil }
		return dockerContainers.first { $0.name == name }
	}

	func container(for service: ManagedService) -> DockerContainer? {
		guard service.isDocker else { return nil }
		if let direct = container(named: service.containerName) { return direct }
		guard service.docker.kind == .compose else { return nil }
		return dockerContainers.first {
			$0.composeService == service.docker.composeService
				&& $0.composeFile == service.docker.composeFile
		}
	}

	var anyRunning: Bool {
		statuses.values.contains { $0.isRunning }
	}

	var anyUsesPortless: Bool {
		services.contains { $0.usesPortless }
	}

	var processServices: [ManagedService] { services.filter { !$0.isDocker } }
	var dockerServices: [ManagedService] { services.filter(\.isDocker) }

	/// Containers docker knows about that no service here claims.
	var unmanagedContainers: [DockerContainer] {
		let claimed = Set(services.filter(\.isDocker).map(\.containerName))
		return dockerContainers
			.filter { !claimed.contains($0.name) }
			.sorted { $0.name < $1.name }
	}

	func effectiveURL(for service: ManagedService) -> String {
		service.effectiveURL(proxy: portless)
	}

	// MARK: - Refresh

	func refreshAll() async {
		async let probe = Portless.probe()
		await refreshDocker()
		portless = await probe
	}

	func refreshPortless() async {
		portless = await Portless.probe()
	}

	func refreshDocker() async {
		if dockerAvailability == nil || dockerAvailability == .daemonDown {
			dockerAvailability = await Docker.availability()
		}
		guard dockerAvailability?.isReady == true else {
			dockerContainers = []
			return
		}
		isRefreshingDocker = true
		dockerContainers = await Docker.snapshot()
		isRefreshingDocker = false
		reconcileDockerStatuses()
	}

	/// Containers can be started or stopped outside this app; trust docker over
	/// our own last-known state, except while a launch is mid-flight.
	private func reconcileDockerStatuses() {
		for service in services where service.isDocker {
			var current = status(for: service.id)
			if current.state.isBusy || stoppingIDs.contains(service.id) { continue }
			guard let container = container(for: service) else {
				if current.isRunning {
					current.state = .stopped
					statuses[service.id] = current
				}
				continue
			}
			if container.isRunning {
				if !current.isUp {
					current.state = .running(pid: 0)
					current.startedAt = current.startedAt ?? Date()
					statuses[service.id] = current
				}
			} else if current.isRunning {
				current.state = .stopped
				current.startedAt = nil
				statuses[service.id] = current
			}
		}
	}

	// MARK: - Environment

	func envContext(for service: ManagedService) -> EnvContext {
		var context = EnvContext(name: service.name)
		context.url = effectiveURL(for: service)

		if service.isDocker {
			var map: [Int: Int] = [:]
			if let container = container(for: service) {
				for port in container.ports {
					if let host = port.hostPort { map[port.containerPort] = host }
				}
			}
			// Not created yet — fall back to what the run spec asks for.
			if map.isEmpty {
				for mapping in service.docker.run.ports where mapping.hostPort > 0 {
					map[mapping.containerPort] = mapping.hostPort
				}
			}
			context.portsByContainerPort = map
			context.primaryPort = map.values.min()
		} else {
			if service.readiness.port > 0 {
				context.primaryPort = service.readiness.port
			} else if let port = URLComponents(string: service.url)?.port {
				context.primaryPort = port
			}
			if let port = context.primaryPort {
				context.portsByContainerPort = [port: port]
			}
		}
		return context
	}

	/// Evaluates against the draft rather than the saved copy, so the editor can
	/// preview edits that have not been committed yet.
	private func withDraft(_ service: ManagedService) -> [ManagedService] {
		var list = services
		if let index = list.firstIndex(where: { $0.id == service.id }) {
			list[index] = service
		} else {
			list.append(service)
		}
		return list
	}

	func servicesWithDraft(_ draft: ManagedService) -> [ManagedService] {
		withDraft(draft)
	}

	/// Distinguishes "another process holds this port" from "our own container
	/// already holds it", which is not a conflict.
	func isPortOwned(by service: ManagedService, port: Int) -> Bool {
		container(for: service)?.publishedPorts.contains(port) ?? false
	}

	/// Dependency contributions first (deepest dependency first), then this
	/// service's own overrides, which always win.
	func resolvedEnvVars(for service: ManagedService) -> [ResolvedEnvVar] {
		let list = withDraft(service)
		var ordered: [String: ResolvedEnvVar] = [:]
		var order: [String] = []

		func put(_ key: String, _ value: String, _ source: String, isOverride: Bool) {
			if ordered[key] == nil { order.append(key) }
			ordered[key] = ResolvedEnvVar(key: key, value: value, source: source, isOverride: isOverride)
		}

		for dependencyID in DependencyGraph.startOrder(for: service.id, in: list) {
			guard let dependency = list.first(where: { $0.id == dependencyID }) else { continue }
			let context = envContext(for: dependency)
			for entry in dependency.providedEnv where entry.isUsable {
				put(entry.trimmedKey, EnvTemplate.expand(entry.value, context: context), dependency.name, isOverride: false)
			}
		}

		let own = envContext(for: service)
		for entry in service.envOverrides where entry.isUsable {
			put(entry.trimmedKey, EnvTemplate.expand(entry.value, context: own), "Override", isOverride: true)
		}

		return order.compactMap { ordered[$0] }
	}

	func resolvedEnvironment(for service: ManagedService) -> [String: String] {
		var environment = ProcessInfo.processInfo.environment
		for variable in resolvedEnvVars(for: service) {
			environment[variable.key] = variable.value
		}
		return environment
	}

	// MARK: - Mutations

	func add(_ service: ManagedService) {
		services.append(service)
		statuses[service.id] = ServiceStatus()
		save()
	}

	func update(_ service: ManagedService) {
		guard let index = services.firstIndex(where: { $0.id == service.id }) else { return }
		services[index] = service
		save()
	}

	func delete(_ id: UUID) {
		stop(id)
		for index in services.indices {
			services[index].dependencies.removeAll { $0 == id }
		}
		services.removeAll { $0.id == id }
		statuses[id] = nil
		save()
	}

	func move(from source: IndexSet, to destination: Int) {
		services.move(fromOffsets: source, toOffset: destination)
		save()
	}

	/// Turns a container docker already knows about into a managed service.
	@discardableResult
	func adopt(_ container: DockerContainer) -> ManagedService {
		var binding = DockerBinding()
		binding.containerName = container.name
		if let file = container.composeFile, let service = container.composeService {
			binding.kind = .compose
			binding.composeFile = file
			binding.composeService = service
		} else {
			binding.kind = .container
		}

		let service = ManagedService(
			name: container.composeService ?? container.name,
			kind: .docker,
			notes: container.image,
			docker: binding
		)
		add(service)
		return service
	}

	func makeCatalogService(
		app: CatalogApp,
		containerName: String,
		hostPorts: [Int: Int],
		env: [EnvEntry],
		enablePortless: Bool
	) -> ManagedService {
		var run = DockerRunSpec()
		run.image = app.image
		run.containerName = containerName
		run.env = env
		run.command = app.command
		run.volumes = app.volumes.map { Catalog.expand(volume: $0, containerName: containerName) }
		run.ports = app.ports.map {
			PortMapping(hostPort: hostPorts[$0.containerPort] ?? $0.suggestedHostPort, containerPort: $0.containerPort)
		}

		var binding = DockerBinding()
		binding.kind = .image
		binding.containerName = containerName
		binding.run = run
		binding.routedContainerPort = app.ports.first(where: \.isHTTP)?.containerPort ?? 0

		return ManagedService(
			name: app.name,
			kind: .docker,
			notes: app.blurb,
			portlessEnabled: enablePortless && app.isWeb,
			portlessName: Portless.slug(from: containerName),
			docker: binding,
			providedEnv: app.providedEnv
		)
	}

	func makeComposeService(file: String, service name: String) -> ManagedService {
		var binding = DockerBinding()
		binding.kind = .compose
		binding.composeFile = file
		binding.composeService = name
		// Compose derives container names itself; the live container is matched by
		// compose labels, so this is only a fallback label.
		binding.containerName = dockerContainers.first {
			$0.composeFile == file && $0.composeService == name
		}?.name ?? name

		return ManagedService(
			name: name,
			kind: .docker,
			notes: "compose: \(URL(fileURLWithPath: file).lastPathComponent)",
			docker: binding
		)
	}

	/// A container built from the folder's own Dockerfile rather than pulled.
	func makeBuildService(
		scan: FolderScan,
		name: String,
		containerName: String,
		dockerfile: String,
		ports: [PortMapping],
		enablePortless: Bool
	) -> ManagedService {
		var run = DockerRunSpec()
		run.image = "toolsui/\(Portless.slug(from: containerName)):latest"
		run.containerName = containerName
		run.buildContext = scan.path
		run.dockerfile = dockerfile
		run.ports = ports

		var binding = DockerBinding()
		binding.kind = .image
		binding.containerName = containerName
		binding.run = run
		binding.routedContainerPort = ports.first?.containerPort ?? 0

		return ManagedService(
			name: name,
			kind: .docker,
			workingDirectory: scan.path,
			notes: "built from \(URL(fileURLWithPath: dockerfile).lastPathComponent)",
			portlessEnabled: enablePortless,
			portlessName: Portless.slug(from: name),
			docker: binding
		)
	}

	func makeCommandService(
		scan: FolderScan,
		name: String,
		command: String,
		enablePortless: Bool
	) -> ManagedService {
		ManagedService(
			name: name,
			kind: .process,
			workingDirectory: scan.path,
			command: command,
			portlessEnabled: enablePortless,
			portlessName: Portless.slug(from: name)
		)
	}

	// MARK: - Start / stop

	func start(_ id: UUID) {
		guard startTasks[id] == nil else { return }
		startTasks[id] = Task { [weak self] in
			await self?.performStart(id)
			self?.startTasks[id] = nil
		}
	}

	private func performStart(_ id: UUID) async {
		guard let service = find(id) else { return }
		if status(for: id).isUp { return }
		lastError = nil

		for dependencyID in DependencyGraph.startOrder(for: id, in: services) {
			if Task.isCancelled { return }
			guard let dependency = find(dependencyID) else { continue }
			if status(for: dependencyID).isUp, await isActuallyUp(dependency) { continue }

			setState(id, .waitingForDependencies(dependency.name))
			appendLog(id, "→ waiting for dependency \(dependency.name)\n")
			await launch(dependencyID)

			guard await waitUntilReady(dependencyID) else {
				let message = "\(dependency.name) never became ready"
				setState(id, .failed(message))
				lastError = "\(service.name): \(message)"
				return
			}
		}

		if Task.isCancelled { return }
		await launch(id)
	}

	private func isActuallyUp(_ service: ManagedService) async -> Bool {
		if service.isDocker {
			return container(for: service)?.isRunning ?? false
		}
		return runners.isRunning(id: service.id)
	}

	private func launch(_ id: UUID) async {
		guard let service = find(id) else { return }
		setState(id, .starting)
		var current = status(for: id)
		current.startedAt = Date()
		statuses[id] = current

		if service.isDocker {
			await launchDocker(service)
		} else {
			launchProcess(service)
		}
	}

	private func launchProcess(_ service: ManagedService) {
		let environment = resolvedEnvironment(for: service)
		let id = service.id

		runners.start(service: service, environment: environment) { [weak self] event in
			Task { @MainActor in
				self?.handle(event, for: id)
			}
		}

		if service.usesPortless {
			Task { [weak self] in
				guard let self else { return }
				await refreshPortless()
				if let hint = portless?.hint {
					lastError = "\(service.name): \(hint)"
				}
			}
		}
	}

	private func launchDocker(_ service: ManagedService) async {
		let id = service.id
		let name = service.containerName
		guard !name.isEmpty else {
			setState(id, .failed("no container name"))
			return
		}

		if dockerAvailability?.isReady != true {
			dockerAvailability = await Docker.availability()
		}
		guard dockerAvailability?.isReady == true else {
			let message = dockerAvailability?.hint ?? "Docker unavailable"
			setState(id, .failed(dockerAvailability?.summary ?? "Docker unavailable"))
			lastError = "\(service.name): \(message)"
			return
		}

		let result: Shell.Result
		switch service.docker.kind {
		case .compose:
			appendLog(id, "$ docker compose up -d \(service.docker.composeService)\n")
			result = await Docker.composeUp(file: service.docker.composeFile, service: service.docker.composeService)
		case .container:
			appendLog(id, "$ docker start \(name)\n")
			result = await Docker.start(name)
		case .image:
			if await Docker.exists(name) {
				appendLog(id, "$ docker start \(name)\n")
				result = await Docker.start(name)
			} else {
				result = await createContainer(service)
			}
		}

		appendLog(id, result.output)
		guard result.isSuccess else {
			setState(id, .failed("docker exit \(result.status)"))
			lastError = "\(service.name): docker failed — \(result.trimmed.suffix(200))"
			return
		}

		await refreshDocker()
		setState(id, .running(pid: 0))
		attachDockerLogs(service)
		await applyPortlessAlias(for: service)
	}

	private func createContainer(_ service: ManagedService) async -> Shell.Result {
		let id = service.id
		var spec = service.docker.run
		spec.containerName = service.containerName
		spec.volumes = spec.volumes.map { Catalog.expand(volume: $0, containerName: spec.containerName) }

		let prepare: String = if spec.isBuilt {
			Docker.buildImageCommand(spec)
		} else {
			"docker pull \(Shell.quote(spec.image))"
		}
		appendLog(id, "$ \(prepare)\n")
		let prepared = await Shell.stream(prepare) { [weak self] chunk in
			Task { @MainActor in self?.appendLog(id, chunk) }
		}
		guard prepared.isSuccess else { return prepared }

		let command = Docker.buildRunCommand(spec)
		appendLog(id, "$ \(command)\n")
		return await Shell.stream(command, timeout: 300) { [weak self] chunk in
			Task { @MainActor in self?.appendLog(id, chunk) }
		}
	}

	private func attachDockerLogs(_ service: ManagedService) {
		let id = service.id
		let name = service.containerName
		guard !name.isEmpty else { return }
		logStreamers.run(
			id: id,
			command: "exec docker logs -f --tail 200 \(Shell.quote(name))"
		) { [weak self] event in
			guard case let .output(text) = event else { return }
			Task { @MainActor in self?.appendLog(id, text) }
		}
	}

	private func applyPortlessAlias(for service: ManagedService) async {
		guard service.usesPortless else { return }
		guard let port = routedHostPort(for: service) else {
			lastError = "\(service.name): no published host port to route. Publish a port on the container first."
			return
		}

		await ensureProxyRunning(for: service)
		let result = await Portless.registerAlias(name: service.resolvedPortlessName, port: port)
		appendLog(service.id, result.output)
		if !result.isSuccess {
			lastError = "\(service.name): portless alias failed — \(result.trimmed.suffix(160))"
		}
		await refreshPortless()
	}

	private func ensureProxyRunning(for service: ManagedService) async {
		if portless == nil { await refreshPortless() }
		guard portless?.isInstalled == true else {
			lastError = "\(service.name): \(Portless.Probe().hint ?? "portless not installed")"
			return
		}
		guard portless?.proxyIsListening != true else { return }

		appendLog(service.id, "$ portless proxy start\n")
		let result = await Portless.startProxy()
		appendLog(service.id, result.output)
		await refreshPortless()

		if portless?.proxyIsListening != true {
			lastError = "\(service.name): the portless proxy could not start on its own (port 443 needs sudo). Open Settings → Portless to start it."
		}
	}

	func routedHostPort(for service: ManagedService) -> Int? {
		let wanted = service.docker.routedContainerPort
		if let container = container(for: service) {
			if wanted > 0, let mapped = container.hostPort(forContainerPort: wanted) { return mapped }
			if let primary = container.primaryHostPort { return primary }
		}
		if wanted > 0, let mapping = service.docker.run.ports.first(where: { $0.containerPort == wanted }) {
			return mapping.hostPort
		}
		return service.docker.run.ports.map(\.hostPort).filter { $0 > 0 }.min()
	}

	// MARK: - Readiness

	private func waitUntilReady(_ id: UUID) async -> Bool {
		guard let service = find(id) else { return false }
		let check = service.readiness
		let deadline = Date().addingTimeInterval(max(5, check.timeout))

		switch resolveMode(for: service) {
		case .immediate:
			return true

		case .dockerHealth:
			while Date() < deadline {
				await refreshDocker()
				if let container = container(for: service) {
					if container.isHealthy { return true }
					if !container.hasHealthcheck, container.isRunning { return true }
					if container.state == "exited" { return false }
				}
				try? await Task.sleep(for: .milliseconds(900))
			}
			return false

		case .tcpPort:
			let port = readinessPort(for: service)
			guard let port, port > 0 else { return true }
			while Date() < deadline {
				if Shell.canConnect(port: UInt16(clamping: port), timeout: 0.6) { return true }
				try? await Task.sleep(for: .milliseconds(500))
			}
			return false

		case .http:
			let target = check.url.isEmpty ? effectiveURL(for: service) : check.url
			guard let url = URL(string: target), !target.isEmpty else { return true }
			while Date() < deadline {
				if await probeHTTP(url) { return true }
				try? await Task.sleep(for: .milliseconds(700))
			}
			return false

		case .auto:
			return true
		}
	}

	/// `.auto` picks the strongest signal each kind can actually offer.
	private func resolveMode(for service: ManagedService) -> ReadinessCheck.Mode {
		guard service.readiness.mode == .auto else { return service.readiness.mode }
		if service.isDocker {
			if container(for: service)?.hasHealthcheck == true { return .dockerHealth }
			return routedHostPort(for: service) != nil ? .tcpPort : .dockerHealth
		}
		return service.readiness.port > 0 ? .tcpPort : .immediate
	}

	private func readinessPort(for service: ManagedService) -> Int? {
		if service.readiness.port > 0 { return service.readiness.port }
		if service.isDocker { return routedHostPort(for: service) }
		return URLComponents(string: service.url)?.port
	}

	private func probeHTTP(_ url: URL) async -> Bool {
		var request = URLRequest(url: url)
		request.timeoutInterval = 3
		request.httpMethod = "GET"
		guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
		guard let http = response as? HTTPURLResponse else { return false }
		return http.statusCode < 500
	}

	// MARK: - Stop

	func stop(_ id: UUID) {
		startTasks[id]?.cancel()
		startTasks[id] = nil

		guard let service = find(id) else { return }
		var current = status(for: id)
		current.state = .stopped
		current.startedAt = nil
		statuses[id] = current

		if service.isDocker {
			logStreamers.stop(id: id)
			stoppingIDs.insert(id)
			Task { [weak self] in
				guard let self else { return }
				defer { stoppingIDs.remove(id) }
				if service.usesPortless {
					await Portless.removeAlias(name: service.resolvedPortlessName)
				}
				let result: Shell.Result = if service.docker.kind == .compose {
					await Docker.composeDown(file: service.docker.composeFile, service: service.docker.composeService)
				} else {
					await Docker.stop(service.containerName)
				}
				appendLog(id, result.output)
				await refreshDocker()
				await refreshPortless()
			}
		} else {
			runners.stop(id: id)
			if service.usesPortless {
				Task { [weak self] in
					await self?.refreshPortless()
				}
			}
		}
	}

	func stopWithDependents(_ id: UUID) {
		for dependent in DependencyGraph.dependents(of: id, in: services).reversed() {
			stop(dependent)
		}
		stop(id)
	}

	func restart(_ id: UUID) {
		stop(id)
		Task { [weak self] in
			try? await Task.sleep(for: .milliseconds(600))
			self?.start(id)
		}
	}

	func stopAll() {
		for service in services {
			stop(service.id)
		}
	}

	/// Quit path: release our own children but leave containers alone, since they
	/// outlive this app and may be shared with other tooling.
	func shutdown() {
		for task in startTasks.values { task.cancel() }
		startTasks.removeAll()
		logStreamers.stopAll()
		runners.stopAll()
	}

	private func startAutoStartServices() async {
		for service in services where service.autoStart {
			start(service.id)
		}
	}

	// MARK: - Container maintenance

	func removeContainer(for service: ManagedService) {
		Task { [weak self] in
			guard let self else { return }
			stop(service.id)
			try? await Task.sleep(for: .milliseconds(400))
			let result = await Docker.remove(service.containerName)
			appendLog(service.id, result.output)
			await refreshDocker()
		}
	}

	// MARK: - Misc actions

	func openURL(_ id: UUID) {
		guard let service = find(id) else { return }
		let trimmed = effectiveURL(for: service)
		guard !trimmed.isEmpty, let url = URL(string: trimmed) else { return }
		NSWorkspace.shared.open(url)
	}

	func openFolder(_ id: UUID) {
		guard let service = find(id) else { return }
		let path = service.workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !path.isEmpty else { return }
		NSWorkspace.shared.open(URL(fileURLWithPath: path, isDirectory: true))
	}

	func clearLog(_ id: UUID) {
		var current = status(for: id)
		current.log = ""
		statuses[id] = current
	}

	// MARK: - Events

	private func setState(_ id: UUID, _ state: ServiceRunState) {
		var current = status(for: id)
		current.state = state
		statuses[id] = current
	}

	private func appendLog(_ id: UUID, _ chunk: String) {
		guard !chunk.isEmpty else { return }
		var current = status(for: id)
		let next = current.log.isEmpty ? chunk : current.log + chunk
		current.log = next.count > 40_000 ? String(next.suffix(30_000)) : next
		statuses[id] = current
	}

	private func handle(_ event: ProcessManager.Event, for id: UUID) {
		var current = status(for: id)
		switch event {
		case let .started(pid):
			current.state = .running(pid: pid)
			current.startedAt = Date()
		case let .output(chunk):
			let next = current.log.isEmpty ? chunk : current.log + chunk
			current.log = next.count > 40_000 ? String(next.suffix(30_000)) : next
		case let .exited(code):
			if case .stopped = current.state { break }
			if code == 0 {
				current.state = .stopped
			} else {
				current.state = .failed("exit \(code)")
				lastError = "\(find(id)?.name ?? "Service") exited \(code)"
			}
			current.startedAt = nil
		case let .failed(message):
			current.state = .failed(message)
			current.startedAt = nil
			lastError = message
		}
		statuses[id] = current
	}

	// MARK: - Persistence

	private func load() {
		guard let data = try? Data(contentsOf: saveURL) else { return }
		guard let decoded = try? JSONDecoder().decode([ManagedService].self, from: data) else { return }
		services = decoded
	}

	func save() {
		guard let data = try? JSONEncoder().encode(services) else { return }
		try? data.write(to: saveURL, options: .atomic)
	}

	private static var seed: [ManagedService] {
		let home = FileManager.default.homeDirectoryForCurrentUser.path
		return [
			ManagedService(
				name: "Frameforge",
				workingDirectory: "\(home)/Documents/open-source/parse-video",
				command: "bun run start",
				url: "http://localhost:3456",
				autoStart: false,
				notes: "Video frame parser"
			),
		]
	}
}
