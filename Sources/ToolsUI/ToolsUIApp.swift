import AppKit
import SwiftUI

enum AppIdentity {
	static let bundleId = "dev.toolsui.app"
	static let activate = Notification.Name("dev.toolsui.activate")
	static let openManager = Notification.Name("dev.toolsui.openManager")
}

@main
struct ToolsUIApp: App {
	@NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
	@State private var store = ServiceStore()
	@State private var showManager = false

	var body: some Scene {
		MenuBarExtra {
			MenuBarView(store: store, showManager: $showManager)
		} label: {
			Label("Tools", systemImage: store.anyRunning ? "bolt.horizontal.circle.fill" : "bolt.horizontal.circle")
				.background(OpenManagerListener())
		}
		.menuBarExtraStyle(.menu)

		Window("Tools UI", id: "manager") {
			ManagerView(store: store)
				.frame(minWidth: 800, minHeight: 520)
				.background(OpenManagerListener())
		}
		.defaultSize(width: 920, height: 600)
		.windowResizability(.contentMinSize)
		.commands {
			CommandGroup(replacing: .newItem) {}
		}

		Settings {
			SettingsView(store: store)
				.frame(width: 420)
		}
	}
}

private struct OpenManagerListener: View {
	@Environment(\.openWindow) private var openWindow

	var body: some View {
		Color.clear
			.frame(width: 0, height: 0)
			.accessibilityHidden(true)
			.onReceive(NotificationCenter.default.publisher(for: AppIdentity.openManager)) { _ in
				openWindow(id: "manager")
				NSApp.activate(ignoringOtherApps: true)
			}
	}
}

final class AppDelegate: NSObject, NSApplicationDelegate {
	func applicationWillFinishLaunching(_ notification: Notification) {
		if Self.otherInstancesExist() {
			DistributedNotificationCenter.default().post(name: AppIdentity.activate, object: nil)
			DistributedNotificationCenter.default().post(name: AppIdentity.openManager, object: nil)
			exit(0)
		}
	}

	func applicationDidFinishLaunching(_ notification: Notification) {
		NSApp.setActivationPolicy(.accessory)

		DistributedNotificationCenter.default().addObserver(
			forName: AppIdentity.activate,
			object: nil,
			queue: .main
		) { _ in
			NSApp.activate(ignoringOtherApps: true)
		}

		DistributedNotificationCenter.default().addObserver(
			forName: AppIdentity.openManager,
			object: nil,
			queue: .main
		) { _ in
			NotificationCenter.default.post(name: AppIdentity.openManager, object: nil)
		}
	}

	func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
		NotificationCenter.default.post(name: AppIdentity.openManager, object: nil)
		return true
	}

	func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
		true
	}

	private static func otherInstancesExist() -> Bool {
		let me = ProcessInfo.processInfo.processIdentifier
		return NSRunningApplication.runningApplications(withBundleIdentifier: AppIdentity.bundleId)
			.contains { $0.processIdentifier != me && !$0.isTerminated }
	}
}
