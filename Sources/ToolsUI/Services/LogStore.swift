import Foundation
import JavaScriptCore
import Observation

enum LogStream: String, Sendable, CaseIterable {
	case stdout, stderr, system
}

enum LogLevel: String, CaseIterable, Sendable {
	case output, trace, debug, info, warn, error, fatal
	var rank: Int { Self.allCases.firstIndex(of: self) ?? 0 }
	var label: String { self == .output ? "Output" : rawValue.uppercased() }

	static func parse(_ value: String) -> LogLevel? {
		switch value.lowercased() {
		case "trace", "10": .trace
		case "debug", "20": .debug
		case "info", "notice", "log", "30": .info
		case "warn", "warning", "40": .warn
		case "error", "err", "50": .error
		case "fatal", "critical", "crit", "60": .fatal
		default: nil
		}
	}
}

struct ParsedLog: Equatable {
	var message: String
	var level: LogLevel = .output
	var source: String = ""
	var timestamp: Date?
	var isInferred = false
}

@MainActor
final class LogParser {
	private let context: JSContext?
	private let ansi = try? NSRegularExpression(pattern: #"\x1B(?:\[[0-?]*[ -/]*[@-~]|\][^\x07]*(?:\x07|\x1B\\))"#)
	private let logfmt = try? NSRegularExpression(pattern: #"(?:^|\s)([A-Za-z_][\w.-]*)=("(?:\\.|[^"\\])*"|\S+)"#)
	private let header = try? NSRegularExpression(pattern: #"^\s*(?:\[?(\d{4}-\d{2}-\d{2}[T ][\d:.]+(?:Z|[+-]\d{2}:?\d{2})?)\]?\s+)?\[?(TRACE|DEBUG|INFO|NOTICE|WARN(?:ING)?|ERROR|ERR|FATAL|CRITICAL)\]?[\s:]+(?:\[([^\]]+)\][\s:|-]*)?(.*)$"#, options: .caseInsensitive)
	private let iso = ISO8601DateFormatter()
	private let fractionalISO = ISO8601DateFormatter()

	init() {
		fractionalISO.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
		let vm = JSContext()
		if let url = Bundle.module.url(forResource: "neural-logline", withExtension: "js"),
			let script = try? String(contentsOf: url, encoding: .utf8) {
			vm?.evaluateScript(script)
		}
		context = vm
	}

	func clean(_ line: String) -> String {
		ansi?.stringByReplacingMatches(in: line, range: NSRange(line.startIndex..., in: line), withTemplate: "") ?? line
	}

	func date(_ value: Any?) -> Date? {
		if let number = value as? NSNumber {
			let seconds = number.doubleValue
			return Date(timeIntervalSince1970: seconds > 100_000_000_000 ? seconds / 1000 : seconds)
		}
		guard let string = value as? String else { return nil }
		return fractionalISO.date(from: string) ?? iso.date(from: string.replacingOccurrences(of: " ", with: "T"))
	}

	func parse(_ line: String) -> ParsedLog {
		let raw = clean(line)
		if let data = raw.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
			let message = object["msg"] as? String ?? object["message"] as? String ?? object["log"] as? String ?? raw
			let value = object["level"] ?? object["severity"] ?? object["lvl"]
			let level = value.map { LogLevel.parse(String(describing: $0)) } ?? nil
			return ParsedLog(message: message, level: level ?? .output,
				source: object["name"] as? String ?? object["logger"] as? String ?? object["source"] as? String ?? object["component"] as? String ?? "",
				timestamp: date(object["time"] ?? object["timestamp"] ?? object["ts"]))
		}
		let fullRange = NSRange(raw.startIndex..., in: raw)
		var fields: [String: String] = [:]
		for match in logfmt?.matches(in: raw, range: fullRange) ?? [] {
			guard let key = Range(match.range(at: 1), in: raw), let value = Range(match.range(at: 2), in: raw) else { continue }
			let text = String(raw[value])
			fields[String(raw[key])] = text.hasPrefix("\"") ? (try? JSONDecoder().decode(String.self, from: Data(text.utf8))) ?? text : text
		}
		if let message = fields["msg"] ?? fields["message"] {
			return ParsedLog(message: message, level: LogLevel.parse(fields["level"] ?? fields["lvl"] ?? "") ?? .output,
				source: fields["source"] ?? fields["logger"] ?? fields["component"] ?? "",
				timestamp: date(fields["time"] ?? fields["ts"] ?? fields["timestamp"]))
		}
		if let match = header?.firstMatch(in: raw, range: fullRange) {
			let parts = (1...4).map { index in Range(match.range(at: index), in: raw).map { String(raw[$0]) } ?? "" }
			return ParsedLog(message: parts[3], level: LogLevel.parse(parts[1]) ?? .output, source: parts[2], timestamp: date(parts[0]))
		}
		if raw.trimmingCharacters(in: .whitespaces).hasPrefix("at ") { return ParsedLog(message: raw) }
		guard raw.count <= 8192,
			let result = context?.objectForKeyedSubscript("__toolsuiParseLog")?.call(withArguments: [raw]),
			(result.forProperty("confidence")?.toDouble() ?? 0) >= 0.8 else { return ParsedLog(message: raw) }
		let level = LogLevel.parse(result.forProperty("level")?.toString() ?? "")
		guard level != nil else { return ParsedLog(message: raw) }
		return ParsedLog(
			message: (result.forProperty("messageConfidence")?.toDouble() ?? 0) >= 0.8 ? result.forProperty("message")?.toString() ?? raw : raw,
			level: level ?? .output,
			source: (result.forProperty("sourceConfidence")?.toDouble() ?? 0) >= 0.8 ? result.forProperty("source")?.toString() ?? "" : "",
			timestamp: date(result.forProperty("timestamp")?.toString()),
			isInferred: true
		)
	}
}

struct LogEntry: Identifiable, Equatable {
	let id: UInt64
	let serviceID: UUID
	let receivedAt: Date
	var raw: String
	var parsed: ParsedLog
	let stream: LogStream
	var timestamp: Date { parsed.timestamp ?? receivedAt }
}

enum LogScope: String, CaseIterable, Identifiable {
	case all = "All output", warnings = "Warnings + errors", errors = "Errors"
	var id: String { rawValue }
	func includes(_ entry: LogEntry) -> Bool {
		switch self {
		case .all: true
		case .warnings: entry.parsed.level.rank >= LogLevel.warn.rank
		case .errors: entry.parsed.level.rank >= LogLevel.error.rank
		}
	}
}

@Observable
@MainActor
final class LogStore {
	var entries: [LogEntry] = []
	private let parser = LogParser()
	private var nextID: UInt64 = 0
	private var pending: [String: UInt64] = [:]
	static let limit = 6000
	static let serviceLimit = 1200
	static let lineLimit = 16_384

	func append(_ chunk: String, serviceID: UUID, stream: LogStream = .system, level: LogLevel? = nil) {
		guard !chunk.isEmpty else { return }
		let key = "\(serviceID)-\(stream.rawValue)"
		var rest = chunk[...]
		while !rest.isEmpty {
			let boundary = rest.firstIndex { $0.isNewline }
			let text = boundary.map { String(rest[..<$0]) } ?? String(rest)
			if let id = pending[key], let index = entries.lastIndex(where: { $0.id == id }) {
				entries[index].raw = String((entries[index].raw + text).suffix(Self.lineLimit))
				entries[index].parsed = parser.parse(entries[index].raw)
				if let level { entries[index].parsed.level = level }
			} else if !text.isEmpty {
				nextID += 1
				let raw = String(text.suffix(Self.lineLimit))
				var parsed = parser.parse(raw)
				if let level { parsed.level = level; parsed.isInferred = false }
				entries.append(LogEntry(id: nextID, serviceID: serviceID, receivedAt: Date(), raw: raw, parsed: parsed, stream: stream))
				pending[key] = nextID
			}
			if let boundary {
				pending[key] = nil
				rest = rest[rest.index(after: boundary)...]
			} else { rest = "" }
		}
		let serviceEntries = entries.filter { $0.serviceID == serviceID }
		if serviceEntries.count > Self.serviceLimit {
			let removed = Set(serviceEntries.prefix(serviceEntries.count - Self.serviceLimit).map(\.id))
			entries.removeAll { removed.contains($0.id) }
		}
		if entries.count > Self.limit { entries.removeFirst(entries.count - Self.limit) }
		let retained = Set(entries.map(\.id))
		pending = pending.filter { retained.contains($0.value) }
	}

	func finish(_ serviceID: UUID) {
		pending = pending.filter { !$0.key.hasPrefix(serviceID.uuidString) }
	}

	func clear(_ serviceID: UUID? = nil) {
		if let serviceID { entries.removeAll { $0.serviceID == serviceID }; finish(serviceID) }
		else { entries.removeAll(); pending.removeAll() }
	}

	static func matches(_ entry: LogEntry, query: String, service: String, checkout: String) -> Bool {
		let words = query.split(whereSeparator: \.isWhitespace)
		let text = "\(service) \(checkout) \(entry.raw) \(entry.parsed.source) \(entry.stream.rawValue)"
		return words.allSatisfy { text.localizedCaseInsensitiveContains($0) }
	}
}

extension LogStore {
	static func export(_ entries: [LogEntry], names: [UUID: String], json: Bool) -> String {
		let iso = ISO8601DateFormatter()
		iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
		return entries.map { entry in
			let name = names[entry.serviceID] ?? entry.serviceID.uuidString
			if !json { return "\(iso.string(from: entry.timestamp)) [\(name)] [\(entry.stream.rawValue)] \(entry.raw)" }
			let record: [String: Any] = ["time": iso.string(from: entry.timestamp), "receivedAt": iso.string(from: entry.receivedAt),
				"service": name, "serviceID": entry.serviceID.uuidString, "stream": entry.stream.rawValue,
				"level": entry.parsed.level.rawValue, "source": entry.parsed.source, "message": entry.parsed.message,
				"raw": entry.raw, "inferred": entry.parsed.isInferred]
			guard let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) else { return entry.raw }
			return String(decoding: data, as: UTF8.self)
		}.joined(separator: "\n") + (entries.isEmpty ? "" : "\n")
	}
}
