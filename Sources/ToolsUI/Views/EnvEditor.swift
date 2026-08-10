import SwiftUI

struct EnvEditor: View {
	@Binding var entries: [EnvEntry]
	var valuePrompt = "value"
	var addLabel = "Add variable"

	var body: some View {
		VStack(alignment: .leading, spacing: 6) {
			ForEach($entries) { $entry in
				HStack(spacing: 8) {
					Toggle("", isOn: $entry.isEnabled)
						.labelsHidden()
						.toggleStyle(.checkbox)
						.help(entry.isEnabled ? "Enabled" : "Disabled")

					TextField("KEY", text: $entry.key)
						.textFieldStyle(.roundedBorder)
						.font(.caption.monospaced())
						.frame(width: 150)

					TextField(valuePrompt, text: $entry.value)
						.textFieldStyle(.roundedBorder)
						.font(.caption.monospaced())

					Button {
						entries.removeAll { $0.id == entry.id }
					} label: {
						Image(systemName: "minus.circle.fill")
							.symbolRenderingMode(.hierarchical)
							.foregroundStyle(.secondary)
					}
					.buttonStyle(.plain)
					.help("Remove")
				}
				.opacity(entry.isEnabled ? 1 : 0.5)
			}

			Button(addLabel, systemImage: "plus") {
				entries.append(EnvEntry())
			}
			.controlSize(.small)
			.padding(.top, 2)
		}
	}
}

/// Read-only view of what a service will actually receive at launch.
struct ResolvedEnvList: View {
	let variables: [ResolvedEnvVar]

	var body: some View {
		if variables.isEmpty {
			Text("No variables contributed. Add a dependency that provides them, or an override below.")
				.font(.caption)
				.foregroundStyle(.tertiary)
		} else {
			VStack(alignment: .leading, spacing: 5) {
				ForEach(variables) { variable in
					HStack(alignment: .firstTextBaseline, spacing: 8) {
						Text(variable.key)
							.font(.caption.monospaced().weight(.semibold))
							.frame(width: 150, alignment: .leading)
							.lineLimit(1)
						Text(variable.value)
							.font(.caption.monospaced())
							.foregroundStyle(.secondary)
							.textSelection(.enabled)
							.lineLimit(1)
							.truncationMode(.middle)
						Spacer(minLength: 4)
						Text(variable.source)
							.font(.caption2.weight(.medium))
							.foregroundStyle(variable.isOverride ? Color.orange : Color.secondary)
							.padding(.horizontal, 6)
							.padding(.vertical, 2)
							.background(
								(variable.isOverride ? Color.orange : Color.secondary).opacity(0.12),
								in: Capsule()
							)
					}
				}
			}
		}
	}
}

struct DependencyPicker: View {
	let candidates: [ManagedService]
	let statusFor: (UUID) -> ServiceStatus
	let wouldCycle: (UUID) -> Bool
	@Binding var selection: [UUID]

	var body: some View {
		if candidates.isEmpty {
			Text("No other services yet. Add a Docker service or another process first.")
				.font(.caption)
				.foregroundStyle(.tertiary)
		} else {
			VStack(alignment: .leading, spacing: 4) {
				ForEach(candidates) { candidate in
					let blocked = wouldCycle(candidate.id)
					Toggle(isOn: binding(for: candidate.id)) {
						HStack(spacing: 8) {
							Image(systemName: candidate.kind.symbol)
								.font(.caption)
								.foregroundStyle(.secondary)
								.frame(width: 14)
							Text(candidate.name)
							if blocked {
								Text("would loop")
									.font(.caption2)
									.foregroundStyle(.orange)
							}
							Spacer(minLength: 0)
							Circle()
								.fill(statusFor(candidate.id).state.tint)
								.frame(width: 6, height: 6)
								.opacity(statusFor(candidate.id).isRunning ? 1 : 0.3)
						}
					}
					.toggleStyle(.checkbox)
					.disabled(blocked)
					.help(blocked ? "\(candidate.name) already depends on this service." : "")
				}
			}
		}
	}

	private func binding(for id: UUID) -> Binding<Bool> {
		Binding(
			get: { selection.contains(id) },
			set: { isOn in
				if isOn {
					if !selection.contains(id) { selection.append(id) }
				} else {
					selection.removeAll { $0 == id }
				}
			}
		)
	}
}
