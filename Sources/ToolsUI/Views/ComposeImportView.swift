import AppKit
import SwiftUI

struct ComposeImportView: View {
	var store: ServiceStore
	var onImport: ([UUID]) -> Void

	@Environment(\.dismiss) private var dismiss
	@State private var file = ""
	@State private var services: [String] = []
	@State private var chosen: Set<String> = []
	@State private var isLoading = false
	@State private var error: String?

	private var knownComposeFiles: [String] {
		var seen: Set<String> = []
		var files: [String] = []
		for container in store.dockerContainers {
			guard let file = container.composeFile, !file.isEmpty, !seen.contains(file) else { continue }
			seen.insert(file)
			files.append(file)
		}
		return files
	}

	var body: some View {
		NavigationStack {
			Form {
				Section {
					LabeledContent("File") {
						HStack(spacing: 8) {
							TextField("compose.yaml", text: $file)
								.labelsHidden()
								.font(.caption.monospaced())
								.onSubmit { load() }
							Button("Choose…") { pickFile() }
						}
					}
					if !knownComposeFiles.isEmpty {
						Menu("Recent from Docker") {
							ForEach(knownComposeFiles, id: \.self) { path in
								Button(path) {
									file = path
									load()
								}
							}
						}
					}
					if let error {
						Label(error, systemImage: "exclamationmark.triangle.fill")
							.font(.caption)
							.foregroundStyle(.orange)
					}
				} header: {
					Text("Compose file")
				} footer: {
					Text("Each selected service becomes a row you can start, stop and depend on. The compose file itself is never modified.")
				}

				Section {
					if isLoading {
						HStack(spacing: 8) {
							ProgressView().controlSize(.small)
							Text("Reading services…")
								.foregroundStyle(.secondary)
						}
					} else if services.isEmpty {
						Text("Choose a compose file to list its services.")
							.font(.caption)
							.foregroundStyle(.tertiary)
					} else {
						ForEach(services, id: \.self) { name in
							Toggle(isOn: binding(for: name)) {
								HStack(spacing: 8) {
									Image(systemName: "shippingbox")
										.font(.caption)
										.foregroundStyle(.secondary)
									Text(name)
									if isAlreadyManaged(name) {
										Text("already added")
											.font(.caption2)
											.foregroundStyle(.tertiary)
									}
								}
							}
							.toggleStyle(.checkbox)
							.disabled(isAlreadyManaged(name))
						}
					}
				} header: {
					Text("Services")
				}
			}
			.formStyle(.grouped)
			.frame(minWidth: 560, minHeight: 420)
			.navigationTitle("Register Compose File")
			.toolbar {
				ToolbarItem(placement: .cancellationAction) {
					Button("Cancel") { dismiss() }
						.keyboardShortcut(.cancelAction)
				}
				ToolbarItem(placement: .confirmationAction) {
					Button("Add \(chosen.count)") { importChosen() }
						.keyboardShortcut(.defaultAction)
						.disabled(chosen.isEmpty)
				}
			}
		}
	}

	private func binding(for name: String) -> Binding<Bool> {
		Binding(
			get: { chosen.contains(name) },
			set: { isOn in
				if isOn { chosen.insert(name) } else { chosen.remove(name) }
			}
		)
	}

	private func isAlreadyManaged(_ name: String) -> Bool {
		store.services.contains {
			$0.isDocker && $0.docker.composeFile == file && $0.docker.composeService == name
		}
	}

	private func load() {
		let path = file.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !path.isEmpty else { return }
		isLoading = true
		error = nil
		chosen = []

		Task {
			let found = await Docker.composeServices(file: path)
			services = found
			isLoading = false
			if found.isEmpty {
				error = "No services found. Check that the path points at a valid compose file."
			}
		}
	}

	private func importChosen() {
		var added: [UUID] = []
		for name in services where chosen.contains(name) {
			let service = store.makeComposeService(file: file, service: name)
			store.add(service)
			added.append(service.id)
		}
		onImport(added)
		dismiss()
	}

	private func pickFile() {
		let panel = NSOpenPanel()
		panel.canChooseFiles = true
		panel.canChooseDirectories = false
		panel.allowsMultipleSelection = false
		panel.message = "Choose a docker compose file"
		if panel.runModal() == .OK, let url = panel.url {
			file = url.path
			load()
		}
	}
}
