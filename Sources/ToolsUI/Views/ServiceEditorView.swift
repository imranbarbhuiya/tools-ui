import AppKit
import SwiftUI

struct ServiceEditorView: View {
	let title: String
	var store: ServiceStore
	var onSave: (ManagedService) -> Void

	@Environment(\.dismiss) private var dismiss
	@State private var draft: ManagedService

	init(
		title: String,
		store: ServiceStore,
		service: ManagedService? = nil,
		onSave: @escaping (ManagedService) -> Void
	) {
		self.title = title
		self.store = store
		self.onSave = onSave
		_draft = State(initialValue: service ?? ManagedService(name: "", command: ""))
	}

	private var canSave: Bool {
		let hasName = !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
		guard hasName else { return false }
		if draft.isDocker {
			return !draft.containerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
		}
		return !draft.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
	}

	private var candidates: [ManagedService] {
		store.services.filter { $0.id != draft.id }
	}

	private var routableContainerPorts: [Int] {
		if let container = store.container(for: draft), !container.ports.isEmpty {
			return container.ports.map(\.containerPort)
		}
		return draft.docker.run.ports.map(\.containerPort)
	}

	var body: some View {
		NavigationStack {
			Form {
				identitySection
				if draft.isDocker { dockerSection } else { processSection }
				dependencySection
				environmentSection
				portlessSection
				readinessSection
				optionsSection
			}
			.formStyle(.grouped)
			.padding(.top, 8)
			.frame(minWidth: 620, minHeight: 520)
			.navigationTitle(title)
			.toolbar {
				ToolbarItem(placement: .cancellationAction) {
					Button("Cancel") { dismiss() }
						.keyboardShortcut(.cancelAction)
				}
				ToolbarItem(placement: .confirmationAction) {
					Button("Save") { save() }
						.keyboardShortcut(.defaultAction)
						.disabled(!canSave)
				}
			}
		}
	}

	// MARK: - Sections

	private var identitySection: some View {
		Section {
			TextField("Name", text: $draft.name, prompt: Text(draft.isDocker ? "Excalidraw" : "Frameforge"))
			LabeledContent("Type") {
				Label(draft.kind.label, systemImage: draft.kind.symbol)
					.font(.caption.weight(.medium))
					.foregroundStyle(.secondary)
			}
		} header: {
			Text("Service")
		}
	}

	private var processSection: some View {
		Section {
			LabeledContent("Directory") {
				HStack(spacing: 8) {
					TextField("Path", text: $draft.workingDirectory, prompt: Text("~/projects/app"))
						.labelsHidden()
						.font(.body.monospaced())
					Button("Choose…") { pickFolder() }
				}
			}
			TextField("Command", text: $draft.command, prompt: Text("bun run start"))
				.font(.body.monospaced())
			if !draft.portlessEnabled {
				TextField("URL", text: $draft.url, prompt: Text("http://localhost:3456"))
					.font(.body.monospaced())
			}
		} header: {
			Text("Command")
		} footer: {
			Text("Runs in zsh with your login PATH, so bun, node and version managers resolve normally.")
		}
	}

	@ViewBuilder
	private var dockerSection: some View {
		Section {
			switch draft.docker.kind {
			case .image:
				LabeledContent(draft.docker.run.isBuilt ? "Builds" : "Image") {
					Text(draft.docker.run.image)
						.font(.caption.monospaced())
						.foregroundStyle(.secondary)
						.textSelection(.enabled)
				}
				if draft.docker.run.isBuilt {
					LabeledContent("From") {
						Text(draft.docker.run.dockerfile)
							.font(.caption.monospaced())
							.foregroundStyle(.secondary)
							.lineLimit(2)
							.truncationMode(.head)
							.textSelection(.enabled)
					}
				}
				TextField("Container", text: $draft.docker.containerName)
					.font(.body.monospaced())
				portMappingEditor
				LabeledContent("Runs") {
					Text(Docker.buildRunCommand(runSpecPreview))
						.font(.caption.monospaced())
						.foregroundStyle(.secondary)
						.lineLimit(4)
						.textSelection(.enabled)
				}
			case .compose:
				LabeledContent("Compose file") {
					Text(draft.docker.composeFile)
						.font(.caption.monospaced())
						.foregroundStyle(.secondary)
						.lineLimit(2)
						.truncationMode(.head)
						.textSelection(.enabled)
				}
				LabeledContent("Service") {
					Text(draft.docker.composeService)
						.font(.caption.monospaced())
						.foregroundStyle(.secondary)
				}
			case .container:
				LabeledContent("Container") {
					Text(draft.docker.containerName)
						.font(.caption.monospaced())
						.foregroundStyle(.secondary)
				}
			}

			if let container = store.container(for: draft), !container.ports.isEmpty {
				LabeledContent("Live ports") {
					Text(container.ports.map(\.label).joined(separator: ", "))
						.font(.caption.monospaced())
						.foregroundStyle(.secondary)
				}
			}
		} header: {
			Text("Docker")
		} footer: {
			Text(dockerFooter)
		}
	}

	private var portMappingEditor: some View {
		LabeledContent("Ports") {
			VStack(alignment: .leading, spacing: 6) {
				ForEach($draft.docker.run.ports) { $mapping in
					HStack(spacing: 6) {
						TextField("host", value: $mapping.hostPort, format: .number.grouping(.never))
							.textFieldStyle(.roundedBorder)
							.font(.caption.monospaced())
							.frame(width: 70)
						Image(systemName: "arrow.right")
							.font(.caption2)
							.foregroundStyle(.tertiary)
						Text("\(mapping.containerPort)")
							.font(.caption.monospaced())
							.foregroundStyle(.secondary)
							.frame(width: 60, alignment: .leading)
						if !Shell.isPortFree(mapping.hostPort), !store.isPortOwned(by: draft, port: mapping.hostPort) {
							Label("in use", systemImage: "exclamationmark.triangle.fill")
								.font(.caption2)
								.foregroundStyle(.orange)
						}
						Spacer(minLength: 0)
					}
				}
			}
		}
	}

	private var dockerFooter: String {
		switch draft.docker.kind {
		case .image where draft.docker.run.isBuilt:
			"The image is built from the folder's Dockerfile on first start, then reused. Delete the container from the service menu to rebuild."
		case .image:
			"The container is created on first start and reused afterwards. Delete it from the service menu to recreate with new settings."
		case .compose, .container:
			"Started and stopped through the docker CLI. Tools UI does not modify the container definition."
		}
	}

	private var runSpecPreview: DockerRunSpec {
		var spec = draft.docker.run
		spec.containerName = draft.containerName
		spec.volumes = spec.volumes.map { Catalog.expand(volume: $0, containerName: draft.containerName) }
		return spec
	}

	private var dependencySection: some View {
		Section {
			DependencyPicker(
				candidates: candidates,
				statusFor: { store.status(for: $0) },
				wouldCycle: { candidate in
					DependencyGraph.wouldCreateCycle(
						adding: candidate,
						to: draft.id,
						in: store.servicesWithDraft(draft)
					)
				},
				selection: $draft.dependencies
			)
		} header: {
			Text("Dependencies")
		} footer: {
			Text("Started in order before this service, each one waited on until ready. Their environment variables are inherited below.")
		}
	}

	private var environmentSection: some View {
		Section {
			DisclosureGroup {
				EnvEditor(entries: $draft.providedEnv, valuePrompt: "postgres://…{{port:5432}}/app")
					.padding(.top, 4)
				Text("Tokens: \(EnvContext.tokenHelp)")
					.font(.caption2)
					.foregroundStyle(.tertiary)
					.padding(.top, 4)
			} label: {
				LabeledContent("Provides") {
					Text(countLabel(draft.providedEnv, noun: "variable"))
						.font(.caption)
						.foregroundStyle(.secondary)
				}
			}

			DisclosureGroup {
				EnvEditor(entries: $draft.envOverrides, valuePrompt: "value", addLabel: "Add override")
					.padding(.top, 4)
			} label: {
				LabeledContent("Overrides") {
					Text(countLabel(draft.envOverrides, noun: "override"))
						.font(.caption)
						.foregroundStyle(.secondary)
				}
			}

			DisclosureGroup {
				ResolvedEnvList(variables: store.resolvedEnvVars(for: draft))
					.padding(.top, 4)
			} label: {
				LabeledContent("Resolved") {
					Text(countLabel(count: store.resolvedEnvVars(for: draft).count, noun: "variable"))
						.font(.caption)
						.foregroundStyle(.secondary)
				}
			}
		} header: {
			Text("Environment")
		} footer: {
			Text("“Provides” is handed to services that depend on this one. “Overrides” apply to this service and win over anything inherited.")
		}
	}

	private var portlessSection: some View {
		Section {
			Toggle("Route through portless", isOn: $draft.portlessEnabled)
			if draft.portlessEnabled {
				TextField(
					"Hostname",
					text: $draft.portlessName,
					prompt: Text(Portless.slug(from: draft.name).isEmpty ? "myapp" : Portless.slug(from: draft.name))
				)
				.font(.body.monospaced())

				if draft.isDocker, routableContainerPorts.count > 1 {
					Picker("Route port", selection: $draft.docker.routedContainerPort) {
						Text("First published").tag(0)
						ForEach(routableContainerPorts, id: \.self) { port in
							Text("container \(port)").tag(port)
						}
					}
				}

				LabeledContent("Opens") {
					Text(draft.resolvedPortlessName.isEmpty ? "—" : draft.portlessURL(proxy: store.portless))
						.font(.caption.monospaced())
						.foregroundStyle(.secondary)
						.textSelection(.enabled)
				}

				if !draft.isDocker {
					LabeledContent("Runs") {
						Text(draft.launchCommand)
							.font(.caption.monospaced())
							.foregroundStyle(.secondary)
							.lineLimit(2)
							.textSelection(.enabled)
					}
				}
			}
		} header: {
			Text("Portless")
		} footer: {
			Text(portlessFooter)
		}
	}

	private var portlessFooter: String {
		guard draft.portlessEnabled else {
			return "Swap the port number for a stable hostname without touching the project's files."
		}
		if draft.isDocker {
			return "Registers a static route (portless alias) to the container's published host port when it starts, and removes it on stop. Portless is an HTTP proxy, so this only helps for ports that speak HTTP."
		}
		return "Portless assigns the port and serves the app at the hostname above. Nothing is written to the project."
	}

	private var readinessSection: some View {
		Section {
			Picker("Ready when", selection: $draft.readiness.mode) {
				ForEach(ReadinessCheck.Mode.allCases) { mode in
					Text(mode.label).tag(mode)
				}
			}
			switch draft.readiness.mode {
			case .tcpPort:
				TextField("Port", value: $draft.readiness.port, format: .number.grouping(.never))
					.font(.body.monospaced())
			case .http:
				TextField("URL", text: $draft.readiness.url, prompt: Text("http://localhost:3000/health"))
					.font(.body.monospaced())
			case .auto, .immediate, .dockerHealth:
				EmptyView()
			}
			if draft.readiness.mode != .immediate {
				LabeledContent("Timeout") {
					HStack {
						Slider(value: $draft.readiness.timeout, in: 5 ... 300, step: 5)
						Text("\(Int(draft.readiness.timeout))s")
							.font(.caption.monospaced())
							.foregroundStyle(.secondary)
							.frame(width: 40, alignment: .trailing)
					}
				}
			}
		} header: {
			Text("Readiness")
		} footer: {
			Text(draft.isDocker
				? "Automatic waits for the container healthcheck when the image defines one, otherwise for its published port to accept a connection."
				: "Anything depending on this service waits for this signal before starting. Automatic does not wait unless a port is set.")
		}
	}

	private var optionsSection: some View {
		Section("Options") {
			Toggle("Start when Tools UI launches", isOn: $draft.autoStart)
			TextField("Notes", text: $draft.notes, prompt: Text("Optional note"), axis: .vertical)
				.lineLimit(2 ... 4)
		}
	}

	// MARK: - Helpers

	private func countLabel(_ entries: [EnvEntry], noun: String) -> String {
		countLabel(count: entries.filter(\.isUsable).count, noun: noun)
	}

	private func countLabel(count: Int, noun: String) -> String {
		count == 1 ? "1 \(noun)" : "\(count) \(noun)s"
	}

	private func save() {
		var service = draft
		service.name = service.name.trimmingCharacters(in: .whitespacesAndNewlines)
		service.command = service.command.trimmingCharacters(in: .whitespacesAndNewlines)
		service.workingDirectory = service.workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
		service.url = service.url.trimmingCharacters(in: .whitespacesAndNewlines)
		service.notes = service.notes.trimmingCharacters(in: .whitespacesAndNewlines)
		service.portlessName = service.portlessName.trimmingCharacters(in: .whitespacesAndNewlines)
		service.docker.containerName = service.docker.containerName.trimmingCharacters(in: .whitespacesAndNewlines)
		service.providedEnv = service.providedEnv.filter { !$0.trimmedKey.isEmpty }
		service.envOverrides = service.envOverrides.filter { !$0.trimmedKey.isEmpty }
		guard !service.name.isEmpty else { return }
		onSave(service)
		dismiss()
	}

	private func pickFolder() {
		let panel = NSOpenPanel()
		panel.canChooseFiles = false
		panel.canChooseDirectories = true
		panel.allowsMultipleSelection = false
		panel.canCreateDirectories = false
		panel.message = "Choose the working directory for this service"
		if !draft.workingDirectory.isEmpty {
			panel.directoryURL = URL(fileURLWithPath: draft.workingDirectory, isDirectory: true)
		}
		if panel.runModal() == .OK, let url = panel.url {
			draft.workingDirectory = url.path
		}
	}
}
