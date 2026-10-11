import AppKit
import SwiftUI

enum AppIdentity {
	static var bundleId: String { Bundle.main.bundleIdentifier ?? "dev.toolsui.app" }
	static var activate: Notification.Name { Notification.Name("\(bundleId).activate") }
	static var openManager: Notification.Name { Notification.Name("\(bundleId).openManager") }
}

@main
struct ToolsUIApp: App {
	@NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
	@State private var store: ServiceStore
	@State private var showManager = false

	init() {
		if let directory = Bundle.main.object(forInfoDictionaryKey: "ToolsUIPortlessStateDirectory") as? String {
			setenv("PORTLESS_STATE_DIR", directory, 1)
		}
		let config = (Bundle.main.object(forInfoDictionaryKey: "ToolsUIConfigPath") as? String).map { URL(fileURLWithPath: $0) }
		_store = State(initialValue: ServiceStore(configURL: config))
	}

	var body: some Scene {
		MenuBarExtra {
			MenuBarView(store: store, showManager: $showManager)
		} label: {
			Label("Tools", systemImage: store.anyRunning ? "bolt.horizontal.circle.fill" : "bolt.horizontal.circle")
				.background(OpenManagerListener())
				.onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in store.shutdown() }
		}
		.menuBarExtraStyle(.menu)

		Window("Tools UI", id: "manager") {
			ManagerView(store: store)
				.frame(minWidth: 800, minHeight: 520)
				.background(OpenManagerListener())
		}
		.defaultSize(width: 1120, height: 760)
		.windowResizability(.contentMinSize)
		.commands {
			CommandGroup(replacing: .newItem) {}
		}

		Window("Ports & Processes", id: "process-finder") {
			ProcessMonitorView(monitor: store.runtime.processes)
				.frame(minWidth: 860, minHeight: 560)
		}
		.defaultSize(width: 1040, height: 680)
		.windowResizability(.contentMinSize)

		Window("Portless Services", id: "portless-services") {
			PortlessRoutesView(monitor: store.runtime.portless)
				.frame(minWidth: 850, minHeight: 520)
		}
		.defaultSize(width: 1100, height: 650)
		.windowResizability(.contentMinSize)

		Window("All Logs", id: "all-logs") { LogsWindow(store: store) }
			.defaultSize(width: 1000, height: 640)
			.windowResizability(.contentMinSize)

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
		if ProcessInfo.processInfo.environment["TOOLSUI_OPEN_MANAGER"] == "1" || Bundle.main.object(forInfoDictionaryKey: "ToolsUIOpenManager") as? Bool == true {
			Task { @MainActor in
				try? await Task.sleep(for: .milliseconds(300))
				NotificationCenter.default.post(name: AppIdentity.openManager, object: nil)
			}
		}

		DistributedNotificationCenter.default().addObserver(
			forName: AppIdentity.activate,
			object: nil,
			queue: .main
		) { _ in
			Task { @MainActor in NSApp.activate(ignoringOtherApps: true) }
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
