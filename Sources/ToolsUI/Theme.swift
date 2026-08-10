import AppKit
import SwiftUI

enum Theme {
	static let sidebarMin: CGFloat = 220
	static let sidebarIdeal: CGFloat = 248
	static let contentMax: CGFloat = 720

	static func monogram(for name: String) -> String {
		let parts = name.split(separator: " ").filter { !$0.isEmpty }
		if parts.count >= 2 {
			return String(parts[0].prefix(1) + parts[1].prefix(1)).uppercased()
		}
		return String(name.prefix(2)).uppercased()
	}

	static func accent(for name: String) -> Color {
		let palette: [Color] = [
			.blue, .indigo, .teal, .cyan, .mint, .purple, .orange, .pink,
		]
		let hash = name.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
		return palette[abs(hash) % palette.count]
	}

	static func appLogoNSImage() -> NSImage? {
		if let named = NSImage(named: "AppIcon") {
			return named
		}
		if let url = Bundle.main.url(forResource: "AppIcon-256", withExtension: "png"),
		   let image = NSImage(contentsOf: url)
		{
			return image
		}
		if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
		   let image = NSImage(contentsOf: url)
		{
			return image
		}
		return nil
	}
}

struct AppLogoView: View {
	var size: CGFloat = 72
	var showShadow = true

	var body: some View {
		Group {
			if let ns = Theme.appLogoNSImage() {
				Image(nsImage: ns)
					.resizable()
					.interpolation(.high)
					.aspectRatio(contentMode: .fit)
			} else {
				ZStack {
					RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
						.fill(
							LinearGradient(
								colors: [
									Color(red: 0.12, green: 0.14, blue: 0.18),
									Color(red: 0.06, green: 0.07, blue: 0.09),
								],
								startPoint: .top,
								endPoint: .bottom
							)
						)
					Image(systemName: "bolt.horizontal.fill")
						.font(.system(size: size * 0.38, weight: .bold))
						.foregroundStyle(
							LinearGradient(
								colors: [
									Color(red: 0.45, green: 0.95, blue: 0.9),
									Color(red: 0.25, green: 0.78, blue: 0.82),
								],
								startPoint: .topLeading,
								endPoint: .bottomTrailing
							)
						)
				}
			}
		}
		.frame(width: size, height: size)
		.clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
		.shadow(color: .black.opacity(showShadow ? 0.28 : 0), radius: showShadow ? 14 : 0, y: showShadow ? 6 : 0)
	}
}

extension ServiceRunState {
	var tint: Color {
		switch self {
		case .running: .green
		case .starting, .waitingForDependencies: .orange
		case .failed: .red
		case .stopped: .secondary
		}
	}

	var symbol: String {
		switch self {
		case .running: "checkmark.circle.fill"
		case .starting: "arrow.triangle.2.circlepath"
		case .waitingForDependencies: "hourglass"
		case .failed: "exclamationmark.triangle.fill"
		case .stopped: "pause.circle.fill"
		}
	}

	var shortLabel: String {
		switch self {
		case .stopped: "Stopped"
		case .starting: "Starting"
		case .waitingForDependencies: "Waiting"
		case .running: "Running"
		case .failed: "Failed"
		}
	}
}

struct StatusChip: View {
	let state: ServiceRunState

	var body: some View {
		Label(state.shortLabel, systemImage: state.symbol)
			.font(.caption.weight(.semibold))
			.foregroundStyle(state.tint)
			.padding(.horizontal, 10)
			.padding(.vertical, 5)
			.background(state.tint.opacity(0.12), in: Capsule())
	}
}

struct ServiceAvatar: View {
	let name: String
	let isRunning: Bool
	var size: CGFloat = 36

	var body: some View {
		ZStack {
			RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
				.fill(
					LinearGradient(
						colors: [
							Theme.accent(for: name).opacity(isRunning ? 0.95 : 0.55),
							Theme.accent(for: name).opacity(isRunning ? 0.65 : 0.35),
						],
						startPoint: .topLeading,
						endPoint: .bottomTrailing
					)
				)
			Text(Theme.monogram(for: name))
				.font(.system(size: size * 0.34, weight: .semibold, design: .rounded))
				.foregroundStyle(.white)
		}
		.frame(width: size, height: size)
		.shadow(color: Theme.accent(for: name).opacity(isRunning ? 0.35 : 0.12), radius: isRunning ? 6 : 2, y: 1)
	}
}

struct InsetCard<Content: View>: View {
	var title: String?
	@ViewBuilder var content: () -> Content

	var body: some View {
		VStack(alignment: .leading, spacing: 10) {
			if let title {
				Text(title)
					.font(.subheadline.weight(.semibold))
					.foregroundStyle(.secondary)
					.padding(.horizontal, 2)
			}
			content()
				.frame(maxWidth: .infinity, alignment: .leading)
				.padding(14)
				.background {
					RoundedRectangle(cornerRadius: 12, style: .continuous)
						.fill(.background.secondary.opacity(0.55))
						.overlay {
							RoundedRectangle(cornerRadius: 12, style: .continuous)
								.strokeBorder(.quaternary, lineWidth: 1)
						}
				}
		}
	}
}

struct MetaRow: View {
	let title: String
	let value: String
	var mono = false

	var body: some View {
		HStack(alignment: .firstTextBaseline, spacing: 16) {
			Text(title)
				.font(.subheadline)
				.foregroundStyle(.secondary)
				.frame(width: 108, alignment: .leading)
			Text(value)
				.font(mono ? .subheadline.monospaced() : .subheadline)
				.foregroundStyle(.primary)
				.textSelection(.enabled)
				.frame(maxWidth: .infinity, alignment: .leading)
		}
		.padding(.vertical, 3)
	}
}
