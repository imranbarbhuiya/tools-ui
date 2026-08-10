import AppKit
import SwiftUI

struct FolderImportView: View {
	var store: ServiceStore
	var onAdd: ([UUID], Bool) -> Void

	@Environment(\.dismiss) private var dismiss

	enum Mode: String, CaseIterable, Identifiable {
		case compose
		case dockerfile
		case command

		var id: String { rawValue }

		var label: String {
			switch self {
			case .compose: "Compose"
			case .dockerfile: "Dockerfile"
			case .command: "Command"
			}
		}

		var symbol: String {
			switch self {
			case .compose: "square.stack.3d.up"
			case .dockerfile: "hammer"
			case .command: "terminal"
			}
		}
	}

	@State private var folder = ""
	@State private var scan = FolderScan()
	@State private var didScan = false
	@State private var mode: Mode = .command

	@State private var name = ""
	@State private var command = ""
	@State private var enablePortless = false
	@State private var startNow = false

	@State private var composeFile = ""
	@State private var composeServices: [String] = []
	@State private var chosenServices: Set<String> = []
	@State private var isLoadingCompose = false

	@State private var containerName = ""
	@State private var dockerfile = ""
	@State private var ports: [PortMapping] = []

	private var availableModes: [Mode] {
		var modes: [Mode] = []
		if scan.hasCompose { modes.append(.compose) }
		if scan.hasDockerfile { modes.append(.dockerfile) }
		modes.append(.command)
		return modes
	}

	private var canAdd: Bool {
		guard didScan, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
		switch mode {
		case .compose: return !chosenServices.isEmpty
		case .dockerfile: return !containerName.isEmpty && !dockerfile.isEmpty
		case .command: return !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
		}
	}

	var body: some View {
		NavigationStack {
			Form {
				folderSection
				if didScan {
					if scan.hasDocker { detectionSection }
					modeSection
					switch mode {
					case .compose: composeSection
					case .dockerfile: dockerfileSection
					case .command: commandSection
					}
					optionsSection
				}
			}
			.formStyle(.grouped)
			.frame(minWidth: 600, minHeight: 520)
			.navigationTitle("Add from Folder")
			.toolbar {
				ToolbarItem(placement: .cancellationAction) {
					Button("Cancel") { dismiss() }
						.keyboardShortcut(.cancelAction)
				}
				ToolbarItem(placement: .confirmationAction) {
					Button(startNow ? "Add & Start" : "Add") { add() }
						.keyboardShortcut(.defaultAction)
						.disabled(!canAdd)
				}
			}
		}
	}

	// MARK: - Sections

	private var folderSection: some View {
		Section {
			LabeledContent("Folder") {
				HStack(spacing: 8) {
					TextField("~/projects/app", text: $folder)
						.labelsHidden()
						.font(.caption.monospaced())
						.onSubmit { runScan() }
					Button("Choose…") { pickFolder() }
				}
			}
			if didScan {
				LabeledContent("Found") {
					Text(scan.summary)
						.font(.caption)
						.foregroundStyle(.secondary)
				}
			}
		} header: {
			Text("Project")
		} footer: {
			Text("Tools UI reads the folder to see how it wants to be started. Nothing in it is modified.")
		}
	}

	private var detectionSection: some View {
		Section {
			HStack(alignment: .top, spacing: 10) {
				Image(systemName: "shippingbox.fill")
					.font(.title3)
					.foregroundStyle(.blue)
				VStack(alignment: .leading, spacing: 3) {
					Text("This folder ships Docker config")
						.font(.callout.weight(.semibold))
					Text(dockerPrompt)
						.font(.caption)
						.foregroundStyle(.secondary)
						.fixedSize(horizontal: false, vertical: true)
				}
				Spacer(minLength: 0)
			}
			.padding(.vertical, 2)
		}
	}

	private var dockerPrompt: String {
		if scan.hasCompose, scan.hasDockerfile {
			return "Found a compose file and a Dockerfile. Compose is selected — switch below to build the Dockerfile directly, or ignore both and just run a command."
		}
		if scan.hasCompose {
			return "Found \(URL(fileURLWithPath: scan.composeFiles[0]).lastPathComponent). Its services are listed below; switch to Command to ignore it."
		}
		return "Found a Dockerfile. Tools UI will build it and run the container; switch to Command to ignore it."
	}

	private var modeSection: some View {
		Section {
			Picker("Start it with", selection: $mode) {
				ForEach(availableModes) { option in
					Label(option.label, systemImage: option.symbol).tag(option)
				}
			}
			.pickerStyle(.segmented)
			TextField("Name", text: $name)
		}
	}

	@ViewBuilder
	private var composeSection: some View {
		Section {
			if scan.composeFiles.count > 1 {
				Picker("File", selection: $composeFile) {
					ForEach(scan.composeFiles, id: \.self) { path in
						Text(URL(fileURLWithPath: path).lastPathComponent).tag(path)
					}
				}
				.onChange(of: composeFile) { _, _ in loadCompose() }
			}

			if isLoadingCompose {
				HStack(spacing: 8) {
					ProgressView().controlSize(.small)
					Text("Reading services…").foregroundStyle(.secondary)
				}
			} else if composeServices.isEmpty {
				Text("No services found in this compose file.")
					.font(.caption)
					.foregroundStyle(.tertiary)
			} else {
				ForEach(composeServices, id: \.self) { service in
					Toggle(isOn: composeBinding(service)) {
						HStack(spacing: 8) {
							Image(systemName: "shippingbox")
								.font(.caption)
								.foregroundStyle(.secondary)
							Text(service)
							if isAlreadyManaged(service) {
								Text("already added")
									.font(.caption2)
									.foregroundStyle(.tertiary)
							}
						}
					}
					.toggleStyle(.checkbox)
					.disabled(isAlreadyManaged(service))
				}
			}
		} header: {
			Text("Compose services")
		} footer: {
			Text("Each one becomes its own row, so you can start them individually or make one depend on another.")
		}
	}

	private var dockerfileSection: some View {
		Section {
			if scan.dockerfiles.count > 1 {
				Picker("Dockerfile", selection: $dockerfile) {
					ForEach(scan.dockerfiles, id: \.self) { path in
						Text(URL(fileURLWithPath: path).lastPathComponent).tag(path)
					}
				}
			}
			TextField("Container", text: $containerName)
				.font(.body.monospaced())

			LabeledContent("Ports") {
				VStack(alignment: .leading, spacing: 6) {
					ForEach($ports) { $mapping in
						HStack(spacing: 6) {
							TextField("host", value: $mapping.hostPort, format: .number.grouping(.never))
								.textFieldStyle(.roundedBorder)
								.font(.caption.monospaced())
								.frame(width: 72)
							Image(systemName: "arrow.right")
								.font(.caption2)
								.foregroundStyle(.tertiary)
							TextField("container", value: $mapping.containerPort, format: .number.grouping(.never))
								.textFieldStyle(.roundedBorder)
								.font(.caption.monospaced())
								.frame(width: 72)
							if !Shell.isPortFree(mapping.hostPort) {
								Label("in use", systemImage: "exclamationmark.triangle.fill")
									.font(.caption2)
									.foregroundStyle(.orange)
							}
							Button {
								ports.removeAll { $0.id == mapping.id }
							} label: {
								Image(systemName: "minus.circle.fill")
									.symbolRenderingMode(.hierarchical)
									.foregroundStyle(.secondary)
							}
							.buttonStyle(.plain)
							Spacer(minLength: 0)
						}
					}
					Button("Add port", systemImage: "plus") {
						ports.append(PortMapping(hostPort: Shell.freePort(from: 8080), containerPort: 8080))
					}
					.controlSize(.small)
				}
			}

			LabeledContent("Builds") {
				Text(Docker.buildImageCommand(previewSpec))
					.font(.caption.monospaced())
					.foregroundStyle(.secondary)
					.lineLimit(2)
					.textSelection(.enabled)
			}
		} header: {
			Text("Build")
		} footer: {
			Text(scan.dockerfilePorts.isEmpty
				? "No EXPOSE line found in the Dockerfile, so set the port yourself. The image is rebuilt only when you delete the container."
				: "Ports were prefilled from the Dockerfile's EXPOSE line. The image is rebuilt only when you delete the container.")
		}
	}

	private var previewSpec: DockerRunSpec {
		DockerRunSpec(
			image: "toolsui/\(Portless.slug(from: containerName.isEmpty ? name : containerName)):latest",
			buildContext: scan.path,
			dockerfile: dockerfile
		)
	}

	private var commandSection: some View {
		Section {
			TextField("Command", text: $command, prompt: Text("bun run dev"))
				.font(.body.monospaced())
			if !scan.scripts.isEmpty {
				Menu("Scripts in package.json") {
					ForEach(scan.scripts, id: \.self) { script in
						Button("\(scan.packageManager) run \(script)") {
							command = "\(scan.packageManager) run \(script)"
						}
					}
				}
			}
		} header: {
			Text("Command")
		} footer: {
			Text("Runs in \(scan.path) through zsh with your login PATH.")
		}
	}

	private var optionsSection: some View {
		Section("Options") {
			Toggle("Give it a portless hostname", isOn: $enablePortless)
			if enablePortless {
				Text(Portless.url(name: Portless.slug(from: name), proxy: store.portless))
					.font(.caption.monospaced())
					.foregroundStyle(.secondary)
					.textSelection(.enabled)
			}
			Toggle("Start after adding", isOn: $startNow)
		}
	}

	// MARK: - Actions

	private func composeBinding(_ service: String) -> Binding<Bool> {
		Binding(
			get: { chosenServices.contains(service) },
			set: { isOn in
				if isOn { chosenServices.insert(service) } else { chosenServices.remove(service) }
			}
		)
	}

	private func isAlreadyManaged(_ service: String) -> Bool {
		store.services.contains {
			$0.isDocker && $0.docker.composeFile == composeFile && $0.docker.composeService == service
		}
	}

	private func pickFolder() {
		let panel = NSOpenPanel()
		panel.canChooseFiles = false
		panel.canChooseDirectories = true
		panel.allowsMultipleSelection = false
		panel.message = "Choose a project folder"
		if panel.runModal() == .OK, let url = panel.url {
			folder = url.path
			runScan()
		}
	}

	private func runScan() {
		let result = FolderScan.scan(path: folder)
		guard !result.path.isEmpty else { return }
		scan = result
		didScan = true

		name = result.projectName
		command = result.suggestedCommand
		containerName = Portless.slug(from: result.projectName)
		dockerfile = result.dockerfiles.first ?? ""
		composeFile = result.composeFiles.first ?? ""
		chosenServices = []
		composeServices = []

		ports = result.dockerfilePorts.isEmpty
			? [PortMapping(hostPort: Shell.freePort(from: 8080), containerPort: 8080)]
			: result.dockerfilePorts.map {
				PortMapping(hostPort: Shell.freePort(from: $0), containerPort: $0)
			}

		// Docker config is the stronger signal, so default to it when present.
		mode = availableModes.first ?? .command
		enablePortless = mode != .compose

		if mode == .compose { loadCompose() }
	}

	private func loadCompose() {
		guard !composeFile.isEmpty else { return }
		isLoadingCompose = true
		Task {
			composeServices = await Docker.composeServices(file: composeFile)
			chosenServices = Set(composeServices.filter { !isAlreadyManaged($0) })
			isLoadingCompose = false
		}
	}

	private func add() {
		var added: [ManagedService] = []

		switch mode {
		case .compose:
			for service in composeServices where chosenServices.contains(service) {
				added.append(store.makeComposeService(file: composeFile, service: service))
			}
		case .dockerfile:
			added.append(store.makeBuildService(
				scan: scan,
				name: name,
				containerName: containerName,
				dockerfile: dockerfile,
				ports: ports,
				enablePortless: enablePortless
			))
		case .command:
			added.append(store.makeCommandService(
				scan: scan,
				name: name,
				command: command,
				enablePortless: enablePortless
			))
		}

		for service in added {
			store.add(service)
		}
		onAdd(added.map(\.id), startNow)
		dismiss()
	}
}
