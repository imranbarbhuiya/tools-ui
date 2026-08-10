import AppKit
import SwiftUI

struct CatalogView: View {
	var store: ServiceStore
	var onAdd: (ManagedService, Bool) -> Void

	@Environment(\.dismiss) private var dismiss
	@State private var search = ""
	@State private var selected: CatalogApp?
	@State private var containerName = ""
	@State private var hostPorts: [Int: Int] = [:]
	@State private var env: [EnvEntry] = []
	@State private var enablePortless = true
	@State private var startNow = true

	@State private var customImage = ""
	@State private var isInspecting = false
	@State private var customPorts: [Int] = []
	@State private var customError: String?

	private var groups: [(String, [CatalogApp])] {
		let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !query.isEmpty else { return Catalog.grouped() }
		return Catalog.grouped().compactMap { category, apps in
			let matches = apps.filter {
				$0.name.localizedCaseInsensitiveContains(query)
					|| $0.blurb.localizedCaseInsensitiveContains(query)
					|| $0.image.localizedCaseInsensitiveContains(query)
			}
			return matches.isEmpty ? nil : (category, matches)
		}
	}

	var body: some View {
		NavigationStack {
			HSplitView {
				list
					.frame(minWidth: 260, idealWidth: 280, maxWidth: 340)
				detail
					.frame(minWidth: 380)
			}
			.frame(minWidth: 720, minHeight: 520)
			.navigationTitle("Add from Docker")
			.toolbar {
				ToolbarItem(placement: .cancellationAction) {
					Button("Cancel") { dismiss() }
						.keyboardShortcut(.cancelAction)
				}
				ToolbarItem(placement: .confirmationAction) {
					Button(startNow ? "Add & Start" : "Add") { add() }
						.keyboardShortcut(.defaultAction)
						.disabled(selected == nil || containerName.isEmpty)
				}
			}
		}
	}

	private var list: some View {
		VStack(spacing: 0) {
			List(selection: Binding(get: { selected?.id }, set: { id in
				if let app = Catalog.apps.first(where: { $0.id == id }) { choose(app) }
			})) {
				ForEach(groups, id: \.0) { category, apps in
					Section(category) {
						ForEach(apps) { app in
							HStack(spacing: 10) {
								Image(systemName: app.symbol)
									.font(.body)
									.foregroundStyle(Theme.accent(for: app.name))
									.frame(width: 22)
								VStack(alignment: .leading, spacing: 1) {
									Text(app.name)
										.font(.body.weight(.medium))
									Text(app.image)
										.font(.caption2.monospaced())
										.foregroundStyle(.tertiary)
										.lineLimit(1)
										.truncationMode(.middle)
								}
								Spacer(minLength: 0)
								if !app.isWeb {
									Image(systemName: "cylinder.fill")
										.font(.caption2)
										.foregroundStyle(.tertiary)
										.help("Not an HTTP service — useful as a dependency")
								}
							}
							.tag(app.id)
						}
					}
				}
			}
			.searchable(text: $search, placement: .sidebar, prompt: "Search apps")

			Divider()
			customImageBar
		}
	}

	private var customImageBar: some View {
		VStack(alignment: .leading, spacing: 6) {
			Text("Any image")
				.font(.caption.weight(.semibold))
				.foregroundStyle(.secondary)
			HStack(spacing: 6) {
				TextField("owner/image:tag", text: $customImage)
					.textFieldStyle(.roundedBorder)
					.font(.caption.monospaced())
					.onSubmit { inspectCustom() }
				Button {
					inspectCustom()
				} label: {
					if isInspecting {
						ProgressView().controlSize(.small)
					} else {
						Image(systemName: "arrow.down.circle")
					}
				}
				.disabled(customImage.trimmingCharacters(in: .whitespaces).isEmpty || isInspecting)
				.help("Pull the image and read its exposed ports")
			}
			if let customError {
				Text(customError)
					.font(.caption2)
					.foregroundStyle(.orange)
					.lineLimit(2)
			}
		}
		.padding(10)
		.background(.bar)
	}

	@ViewBuilder
	private var detail: some View {
		if let app = selected {
			ScrollView {
				VStack(alignment: .leading, spacing: 18) {
					header(app)

					InsetCard(title: "Container") {
						VStack(alignment: .leading, spacing: 10) {
							LabeledContent("Name") {
								TextField("container-name", text: $containerName)
									.textFieldStyle(.roundedBorder)
									.font(.caption.monospaced())
							}
							if store.container(named: containerName) != nil {
								Label("A container with this name already exists — pick another.", systemImage: "exclamationmark.triangle.fill")
									.font(.caption)
									.foregroundStyle(.orange)
							}
						}
					}

					InsetCard(title: "Ports") {
						VStack(alignment: .leading, spacing: 8) {
							ForEach(app.ports, id: \.containerPort) { port in
								HStack(spacing: 8) {
									TextField(
										"host",
										value: Binding(
											get: { hostPorts[port.containerPort] ?? port.suggestedHostPort },
											set: { hostPorts[port.containerPort] = $0 }
										),
										format: .number.grouping(.never)
									)
									.textFieldStyle(.roundedBorder)
									.font(.caption.monospaced())
									.frame(width: 72)

									Image(systemName: "arrow.right")
										.font(.caption2)
										.foregroundStyle(.tertiary)

									Text("\(port.containerPort)")
										.font(.caption.monospaced())
										.frame(width: 54, alignment: .leading)

									Text(port.label)
										.font(.caption)
										.foregroundStyle(.secondary)

									if !port.isHTTP {
										Text("TCP")
											.font(.caption2.weight(.medium))
											.foregroundStyle(.tertiary)
											.padding(.horizontal, 5)
											.padding(.vertical, 1)
											.background(Color.secondary.opacity(0.12), in: Capsule())
									}

									Spacer(minLength: 0)

									if !Shell.isPortFree(hostPorts[port.containerPort] ?? port.suggestedHostPort) {
										Label("in use", systemImage: "exclamationmark.triangle.fill")
											.font(.caption2)
											.foregroundStyle(.orange)
									}
								}
							}
						}
					}

					if !env.isEmpty {
						InsetCard(title: "Environment") {
							EnvEditor(entries: $env)
						}
					}

					if !app.providedEnv.isEmpty {
						InsetCard(title: "Provides to dependents") {
							VStack(alignment: .leading, spacing: 4) {
								ForEach(app.providedEnv) { entry in
									HStack(alignment: .firstTextBaseline, spacing: 8) {
										Text(entry.key)
											.font(.caption.monospaced().weight(.semibold))
											.frame(width: 130, alignment: .leading)
										Text(entry.value)
											.font(.caption.monospaced())
											.foregroundStyle(.secondary)
											.lineLimit(1)
											.truncationMode(.middle)
									}
								}
								Text("Any service that depends on this one inherits these.")
									.font(.caption2)
									.foregroundStyle(.tertiary)
									.padding(.top, 2)
							}
						}
					}

					InsetCard(title: "Options") {
						VStack(alignment: .leading, spacing: 8) {
							Toggle("Give it a portless hostname", isOn: $enablePortless)
								.disabled(!app.isWeb)
							if enablePortless, app.isWeb {
								Text(Portless.url(name: Portless.slug(from: containerName), proxy: store.portless))
									.font(.caption.monospaced())
									.foregroundStyle(.secondary)
									.textSelection(.enabled)
							} else if !app.isWeb {
								Text("This image speaks a non-HTTP protocol, so a portless hostname would not serve it. Use it as a dependency instead.")
									.font(.caption)
									.foregroundStyle(.tertiary)
							}
							Toggle("Start after adding", isOn: $startNow)
						}
					}
				}
				.padding(22)
				.frame(maxWidth: .infinity, alignment: .leading)
			}
			.background()
		} else {
			ContentUnavailableView {
				Label("Pick an app", systemImage: "shippingbox")
			} description: {
				Text("Choose a packaged app to run in Docker, or pull any image by name below the list.")
			}
			.background()
		}
	}

	private func header(_ app: CatalogApp) -> some View {
		HStack(alignment: .top, spacing: 14) {
			RoundedRectangle(cornerRadius: 14, style: .continuous)
				.fill(Theme.accent(for: app.name).gradient.opacity(0.85))
				.frame(width: 54, height: 54)
				.overlay {
					Image(systemName: app.symbol)
						.font(.system(size: 24, weight: .semibold))
						.foregroundStyle(.white)
				}
			VStack(alignment: .leading, spacing: 4) {
				Text(app.name)
					.font(.system(.title2, design: .rounded).weight(.semibold))
				Text(app.blurb)
					.font(.subheadline)
					.foregroundStyle(.secondary)
				Text(app.image)
					.font(.caption.monospaced())
					.foregroundStyle(.tertiary)
					.textSelection(.enabled)
			}
			Spacer(minLength: 0)
		}
	}

	// MARK: - Actions

	private func choose(_ app: CatalogApp) {
		selected = app
		containerName = uniqueName(base: app.id)
		env = app.env
		enablePortless = app.isWeb
		hostPorts = [:]
		for port in app.ports {
			hostPorts[port.containerPort] = Shell.freePort(
				from: port.suggestedHostPort,
				avoiding: Set(hostPorts.values)
			)
		}
	}

	private func uniqueName(base: String) -> String {
		let slug = Portless.slug(from: base)
		var candidate = slug
		var suffix = 2
		while store.container(named: candidate) != nil {
			candidate = "\(slug)-\(suffix)"
			suffix += 1
		}
		return candidate
	}

	/// Pulls an arbitrary image and reads its EXPOSE list so the port fields can
	/// be prefilled without the user knowing the image internals.
	private func inspectCustom() {
		let image = customImage.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !image.isEmpty else { return }
		isInspecting = true
		customError = nil

		Task {
			if await !Docker.imageExists(image) {
				let pull = await Shell.run("docker pull \(Shell.quote(image))", timeout: 900)
				guard pull.isSuccess else {
					customError = "Could not pull \(image)."
					isInspecting = false
					return
				}
			}
			customPorts = await Docker.exposedPorts(image)
			isInspecting = false

			let name = image
				.split(separator: "/").last
				.map { $0.split(separator: ":").first.map(String.init) ?? String($0) } ?? image

			let ports: [CatalogPort] = customPorts.isEmpty
				? [CatalogPort(80, host: 8080, label: "Web")]
				: customPorts.enumerated().map { index, port in
					CatalogPort(port, host: port, label: index == 0 ? "Primary" : "Port \(port)")
				}

			if customPorts.isEmpty {
				customError = "\(image) declares no EXPOSE ports — set the port manually."
			}

			choose(CatalogApp(
				id: "custom:\(image)",
				name: name.capitalized,
				image: image,
				blurb: "Custom image.",
				category: "Apps",
				symbol: "shippingbox.fill",
				ports: ports
			))
		}
	}

	private func add() {
		guard let app = selected else { return }
		var resolved = hostPorts
		for port in app.ports where resolved[port.containerPort] == nil {
			resolved[port.containerPort] = port.suggestedHostPort
		}

		let service = store.makeCatalogService(
			app: app,
			containerName: containerName,
			hostPorts: resolved,
			env: env,
			enablePortless: enablePortless
		)
		onAdd(service, startNow)
		dismiss()
	}
}
