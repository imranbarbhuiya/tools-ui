import SwiftUI

struct ServiceDetailView: View {
	@Bindable var store: ServiceStore
	let service: ManagedService
	var onEdit: () -> Void
	var onDelete: () -> Void
	var onShowLog: () -> Void

	private var status: ServiceStatus { store.status(for: service.id) }
	private var container: DockerContainer? { store.container(for: service) }
	private var url: String { store.effectiveURL(for: service) }

	private var dependencies: [ManagedService] {
		service.dependencies.compactMap { store.find($0) }
	}

	private var dependents: [ManagedService] {
		DependencyGraph.dependents(of: service.id, in: store.services).compactMap { store.find($0) }
	}

	var body: some View {
		ScrollView {
			VStack(alignment: .leading, spacing: 22) {
				header
				actionBar
				if !dependencies.isEmpty || !dependents.isEmpty { dependencyCard }
				configurationCard
				environmentCard
				logCard
			}
			.frame(maxWidth: Theme.contentMax, alignment: .leading)
			.frame(maxWidth: .infinity, alignment: .leading)
			.padding(28)
		}
		.background()
		.toolbar {
			ToolbarItemGroup(placement: .primaryAction) {
				if status.isRunning {
					Button {
						store.restart(service.id)
					} label: {
						Label("Restart", systemImage: "arrow.clockwise")
					}
					Button(role: .destructive) {
						store.stop(service.id)
					} label: {
						Label("Stop", systemImage: "stop.fill")
					}
				} else {
					Button {
						store.start(service.id)
					} label: {
						Label("Start", systemImage: "play.fill")
					}
					.keyboardShortcut(.return, modifiers: [.command])
				}

				Menu {
					if !url.isEmpty {
						Button("Open URL", systemImage: "safari") { store.openURL(service.id) }
					}
					if !service.workingDirectory.isEmpty {
						Button("Reveal in Finder", systemImage: "folder") { store.openFolder(service.id) }
					}
					Button("Full Log…", systemImage: "doc.plaintext") { onShowLog() }
					Divider()
					Button("Edit…", systemImage: "pencil") { onEdit() }
					if service.isDocker, service.docker.kind == .image {
						Button("Delete Container", systemImage: "trash.slash") {
							store.removeContainer(for: service)
						}
						.help("Removes the container so the next start recreates it with current settings")
					}
					Button("Remove from Tools UI", systemImage: "trash", role: .destructive) { onDelete() }
				} label: {
					Label("More", systemImage: "ellipsis.circle")
				}
			}
		}
	}

	private var header: some View {
		HStack(alignment: .center, spacing: 16) {
			ServiceAvatar(name: service.name, isRunning: status.isRunning, size: 56)
			VStack(alignment: .leading, spacing: 6) {
				Text(service.name)
					.font(.system(.largeTitle, design: .rounded).weight(.semibold))
				HStack(spacing: 8) {
					StatusChip(state: status.state)
					Label(service.kind.label, systemImage: service.kind.symbol)
						.font(.caption.weight(.medium))
						.foregroundStyle(.tertiary)
					if case let .running(pid) = status.state, pid > 0 {
						Text("PID \(pid)")
							.font(.caption.monospaced())
							.foregroundStyle(.tertiary)
					}
					if let started = status.startedAt, status.isRunning {
						Text("\(started, style: .relative) ago")
							.font(.caption)
							.foregroundStyle(.tertiary)
					}
				}
				if !service.notes.isEmpty {
					Text(service.notes)
						.font(.subheadline)
						.foregroundStyle(.secondary)
						.lineLimit(2)
				}
			}
			Spacer(minLength: 0)
		}
	}

	private var actionBar: some View {
		HStack(spacing: 10) {
			if status.isRunning {
				Button {
					store.stop(service.id)
				} label: {
					Label("Stop", systemImage: "stop.fill")
						.frame(minWidth: 88)
				}
				.buttonStyle(.borderedProminent)
				.tint(.red)
				.controlSize(.large)

				Button {
					store.restart(service.id)
				} label: {
					Label("Restart", systemImage: "arrow.clockwise")
				}
				.buttonStyle(.bordered)
				.controlSize(.large)
			} else {
				Button {
					store.start(service.id)
				} label: {
					Label(dependencies.isEmpty ? "Start" : "Start \(dependencies.count + 1)", systemImage: "play.fill")
						.frame(minWidth: 88)
				}
				.buttonStyle(.borderedProminent)
				.controlSize(.large)
				.help(dependencies.isEmpty
					? "Start this service"
					: "Starts \(dependencies.map(\.name).joined(separator: ", ")) first")
			}

			if !url.isEmpty {
				Button {
					store.openURL(service.id)
				} label: {
					Label("Open", systemImage: "safari")
				}
				.buttonStyle(.bordered)
				.controlSize(.large)
			}

			if !service.workingDirectory.isEmpty {
				Button {
					store.openFolder(service.id)
				} label: {
					Label("Folder", systemImage: "folder")
				}
				.buttonStyle(.bordered)
				.controlSize(.large)
			}

			Spacer(minLength: 0)
		}
	}

	private var dependencyCard: some View {
		InsetCard(title: "Dependencies") {
			VStack(alignment: .leading, spacing: 12) {
				if !dependencies.isEmpty {
					VStack(alignment: .leading, spacing: 6) {
						Text("Starts first, in order")
							.font(.caption)
							.foregroundStyle(.secondary)
						ForEach(Array(dependencies.enumerated()), id: \.element.id) { index, dependency in
							dependencyRow(dependency, index: index + 1)
						}
					}
				}
				if !dependents.isEmpty {
					VStack(alignment: .leading, spacing: 6) {
						Text("Needed by")
							.font(.caption)
							.foregroundStyle(.secondary)
						ForEach(dependents) { dependent in
							HStack(spacing: 8) {
								Image(systemName: dependent.kind.symbol)
									.font(.caption)
									.foregroundStyle(.tertiary)
									.frame(width: 14)
								Text(dependent.name)
									.font(.callout)
								Spacer(minLength: 0)
								Circle()
									.fill(store.status(for: dependent.id).state.tint)
									.frame(width: 6, height: 6)
							}
						}
					}
				}
			}
		}
	}

	private func dependencyRow(_ dependency: ManagedService, index: Int) -> some View {
		HStack(spacing: 8) {
			Text("\(index)")
				.font(.caption2.monospaced().weight(.semibold))
				.foregroundStyle(.tertiary)
				.frame(width: 14)
			Image(systemName: dependency.kind.symbol)
				.font(.caption)
				.foregroundStyle(.secondary)
				.frame(width: 14)
			Text(dependency.name)
				.font(.callout)
			Text(dependency.readiness.summary)
				.font(.caption2)
				.foregroundStyle(.tertiary)
			Spacer(minLength: 0)
			StatusChip(state: store.status(for: dependency.id).state)
				.scaleEffect(0.85)
		}
	}

	private var configurationCard: some View {
		InsetCard(title: "Configuration") {
			VStack(spacing: 0) {
				if service.isDocker {
					MetaRow(title: "Container", value: service.containerName, mono: true)
					divider
					MetaRow(title: "Image", value: dockerImageText, mono: true)
					divider
					MetaRow(title: "Ports", value: portsText, mono: true)
				} else {
					MetaRow(title: "Command", value: service.command, mono: true)
					divider
					MetaRow(
						title: "Directory",
						value: service.workingDirectory.isEmpty ? "—" : service.workingDirectory,
						mono: true
					)
				}
				divider
				MetaRow(title: "URL", value: url.isEmpty ? "—" : url, mono: true)
				divider
				MetaRow(
					title: "Portless",
					value: service.usesPortless ? service.resolvedPortlessName : "Off",
					mono: service.usesPortless
				)
				divider
				MetaRow(title: "Ready when", value: service.readiness.summary)
				divider
				MetaRow(title: "Auto-start", value: service.autoStart ? "On launch" : "Manual")
			}
		}
	}

	private var divider: some View {
		Divider().padding(.leading, 108)
	}

	private var dockerImageText: String {
		if service.docker.kind == .image { return service.docker.run.image }
		if let container { return container.image }
		if service.docker.kind == .compose { return "compose: \(service.docker.composeService)" }
		return "—"
	}

	private var portsText: String {
		if let container, !container.ports.isEmpty {
			return container.ports.map(\.label).joined(separator: ", ")
		}
		let planned = service.docker.run.ports
		guard !planned.isEmpty else { return "—" }
		return planned.map { "\($0.hostPort)→\($0.containerPort)" }.joined(separator: ", ")
	}

	private var environmentCard: some View {
		InsetCard(title: "Environment") {
			VStack(alignment: .leading, spacing: 12) {
				let resolved = store.resolvedEnvVars(for: service)
				ResolvedEnvList(variables: resolved)

				if !service.providedEnv.filter(\.isUsable).isEmpty {
					Divider()
					VStack(alignment: .leading, spacing: 6) {
						Text("Provides to dependents")
							.font(.caption)
							.foregroundStyle(.secondary)
						ForEach(service.providedEnv.filter(\.isUsable)) { entry in
							HStack(alignment: .firstTextBaseline, spacing: 8) {
								Text(entry.trimmedKey)
									.font(.caption.monospaced().weight(.semibold))
									.frame(width: 150, alignment: .leading)
								Text(EnvTemplate.expand(entry.value, context: store.envContext(for: service)))
									.font(.caption.monospaced())
									.foregroundStyle(.secondary)
									.textSelection(.enabled)
									.lineLimit(1)
									.truncationMode(.middle)
								Spacer(minLength: 0)
							}
						}
					}
				}
			}
		}
	}

	private var logCard: some View {
		InsetCard(title: "Output") {
			VStack(alignment: .leading, spacing: 10) {
				ScrollView {
					Text(status.log.isEmpty ? "No output yet. Start the service to stream logs here." : status.log)
						.font(.system(.caption, design: .monospaced))
						.foregroundStyle(status.log.isEmpty ? .tertiary : .primary)
						.frame(maxWidth: .infinity, alignment: .leading)
						.textSelection(.enabled)
				}
				.frame(minHeight: 180, maxHeight: 300)
				.padding(10)
				.background {
					RoundedRectangle(cornerRadius: 8, style: .continuous)
						.fill(Color.primary.opacity(0.04))
				}

				HStack {
					Button("Full log", systemImage: "arrow.up.left.and.arrow.down.right", action: onShowLog)
						.controlSize(.small)
					Spacer()
					Button("Clear", systemImage: "trash") { store.clearLog(service.id) }
						.controlSize(.small)
						.disabled(status.log.isEmpty)
				}
			}
		}
	}
}
