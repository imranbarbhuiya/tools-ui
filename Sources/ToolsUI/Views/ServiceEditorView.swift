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

	var body: some View {
		NavigationStack {
			Form {
				TextField("Name", text: $draft.name)
				TextField("Working directory", text: $draft.workingDirectory)
				HStack {
					Spacer()
					Button("Choose…") { pickFolder() }
				}
				TextField("Command", text: $draft.command, prompt: Text("bun run start"))
				TextField("URL", text: $draft.url, prompt: Text("http://localhost:3456"))
				Toggle("Start with Tools UI", isOn: $draft.autoStart)
				TextField("Notes", text: $draft.notes, axis: .vertical)
					.lineLimit(2 ... 4)
			}
			.formStyle(.grouped)
			.padding()
			.frame(width: 480)
			.navigationTitle(title)
			.toolbar {
				ToolbarItem(placement: .cancellationAction) {
					Button("Cancel") { dismiss() }
				}
				ToolbarItem(placement: .confirmationAction) {
					Button("Save") {
						var s = draft
						s.name = s.name.trimmingCharacters(in: .whitespacesAndNewlines)
						s.command = s.command.trimmingCharacters(in: .whitespacesAndNewlines)
						s.workingDirectory = s.workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
						s.url = s.url.trimmingCharacters(in: .whitespacesAndNewlines)
						guard !s.name.isEmpty, !s.command.isEmpty else { return }
						onSave(s)
						dismiss()
					}
					.disabled(draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
						|| draft.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
				}
			}
		}
	}

	private func pickFolder() {
		let panel = NSOpenPanel()
		panel.canChooseFiles = false
		panel.canChooseDirectories = true
		panel.allowsMultipleSelection = false
		panel.canCreateDirectories = false
		if !draft.workingDirectory.isEmpty {
			panel.directoryURL = URL(fileURLWithPath: draft.workingDirectory, isDirectory: true)
		}
		if panel.runModal() == .OK, let url = panel.url {
			draft.workingDirectory = url.path
		}
	}
}
