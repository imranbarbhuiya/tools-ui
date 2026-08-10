import AppKit
import SwiftUI

struct ServiceEditorView: View {
	let title: String
	var onSave: (ManagedService) -> Void

	@Environment(\.dismiss) private var dismiss
	@State private var draft: ManagedService

	init(title: String, service: ManagedService? = nil, onSave: @escaping (ManagedService) -> Void) {
		self.title = title
		self.onSave = onSave
		_draft = State(initialValue: service ?? ManagedService(name: "", command: ""))
	}

	private var canSave: Bool {
		!draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
			&& !draft.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
	}

	var body: some View {
		NavigationStack {
			Form {
				Section {
					TextField("Name", text: $draft.name, prompt: Text("Frameforge"))
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
					Text("Service")
				} footer: {
					Text("Commands run in zsh with your login PATH, so tools like bun and node resolve normally.")
				}

				Section {
					Toggle("Route through portless", isOn: $draft.portlessEnabled)
					if draft.portlessEnabled {
						TextField(
							"Hostname",
							text: $draft.portlessName,
							prompt: Text(Portless.slug(from: draft.name).isEmpty ? "myapp" : Portless.slug(from: draft.name))
						)
						.font(.body.monospaced())
						LabeledContent("Opens") {
							Text(draft.resolvedPortlessName.isEmpty ? "—" : draft.portlessURL)
								.font(.caption.monospaced())
								.foregroundStyle(.secondary)
								.textSelection(.enabled)
						}
						LabeledContent("Runs") {
							Text(draft.launchCommand)
								.font(.caption.monospaced())
								.foregroundStyle(.secondary)
								.lineLimit(2)
								.textSelection(.enabled)
						}
					}
				} header: {
					Text("Portless")
				} footer: {
					Text(draft.portlessEnabled
						? "Portless assigns the port and serves the app at the hostname above. Nothing is written to the project — no portless.json, no package.json change. Needs portless on your PATH and a running proxy (see Settings)."
						: "Swap the port number for a stable https:// hostname without touching the project's files.")
				}

				Section("Options") {
					Toggle("Start when Tools UI launches", isOn: $draft.autoStart)
					TextField("Notes", text: $draft.notes, prompt: Text("Optional note"), axis: .vertical)
						.lineLimit(2 ... 4)
				}
			}
			.formStyle(.grouped)
			.padding(.top, 8)
			.frame(minWidth: 500, minHeight: 360)
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

	private func save() {
		var s = draft
		s.name = s.name.trimmingCharacters(in: .whitespacesAndNewlines)
		s.command = s.command.trimmingCharacters(in: .whitespacesAndNewlines)
		s.workingDirectory = s.workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
		s.url = s.url.trimmingCharacters(in: .whitespacesAndNewlines)
		s.notes = s.notes.trimmingCharacters(in: .whitespacesAndNewlines)
		s.portlessName = s.portlessName.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !s.name.isEmpty, !s.command.isEmpty else { return }
		onSave(s)
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
