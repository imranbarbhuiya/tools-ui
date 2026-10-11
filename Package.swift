// swift-tools-version: 6.0
import PackageDescription

let package = Package(
	name: "ToolsUI",
	platforms: [
		.macOS(.v14),
	],
	products: [
		.executable(name: "ToolsUI", targets: ["ToolsUI"]),
	],
	targets: [
		.executableTarget(
			name: "ToolsUI",
			path: "Sources/ToolsUI",
			exclude: ["AppIcon.png"],
			resources: [.copy("Resources/neural-logline.js"), .copy("Resources/NOTICE-neural-logline.txt")],
		),
		.testTarget(name: "ToolsUITests", dependencies: ["ToolsUI"]),
	],
)
