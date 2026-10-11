import Foundation

struct Checkout: Identifiable, Hashable, Sendable {
	var id: String { directory }
	let directory: String
	let repository: String
	let branch: String
	let revision: String
	let isLinked: Bool
	let changedFiles: Int
	var name: String { URL(fileURLWithPath: repository).lastPathComponent }
	var label: String { branch.isEmpty ? "Detached · \(revision)" : branch }

	static func inspect(_ directory: String) async -> Checkout? {
		let git = "GIT_OPTIONAL_LOCKS=0 git -C \(Shell.quote(directory))"
		let paths = await Shell.run("\(git) rev-parse --path-format=absolute --show-toplevel --git-common-dir --git-dir", timeout: 5)
		guard paths.isSuccess else { return nil }
		let lines = paths.output.split(separator: "\n").map(String.init)
		guard lines.count == 3 else { return nil }
		async let branch = Shell.run("\(git) symbolic-ref --quiet --short HEAD", timeout: 5)
		async let revision = Shell.run("\(git) rev-parse --short HEAD", timeout: 5)
		async let status = Shell.run("\(git) status --porcelain=v1 -z --untracked-files=normal", timeout: 5)
		let results = await (branch, revision, status)
		return Checkout(
			directory: canonical(lines[0]),
			repository: URL(fileURLWithPath: canonical(lines[1])).deletingLastPathComponent().path,
			branch: results.0.isSuccess ? results.0.trimmed : "",
			revision: results.1.isSuccess ? results.1.trimmed : "Unborn",
			isLinked: canonical(lines[1]) != canonical(lines[2]),
			changedFiles: results.2.isSuccess ? changedFileCount(results.2.output) : 0
		)
	}

	static func canonical(_ path: String) -> String {
		guard !path.isEmpty else { return "" }
		return URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.resolvingSymlinksInPath().path
	}

	static func contains(_ directory: String, in root: String) -> Bool {
		directory == root || directory.hasPrefix(root + "/")
	}

	static func changedFileCount(_ porcelain: String) -> Int {
		let records = porcelain.split(separator: "\0")
		var index = 0
		var count = 0
		while index < records.count {
			let status = records[index].prefix(2)
			count += 1
			index += status.contains("R") || status.contains("C") ? 2 : 1
		}
		return count
	}
}
