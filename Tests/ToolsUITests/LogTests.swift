import Foundation
import Testing
@testable import ToolsUI

@Suite @MainActor struct LogTests {
	@Test func exactStructuredFormatsAndANSI() {
		let parser = LogParser()
		let json = parser.parse(#"{"level":50,"time":1720000000000,"name":"api","msg":"failed 🌍","request":{"id":3}}"#)
		#expect(json.level == .error)
		#expect(json.message == "failed 🌍")
		#expect(json.source == "api")
		#expect(json.timestamp == Date(timeIntervalSince1970: 1720000000))
		#expect(!json.isInferred)
		let fmt = parser.parse(#"ts=2026-10-11T12:34:56.123Z level=warn component=db msg="retry \"connection\"" attempts=3"#)
		#expect(fmt.level == .warn)
		#expect(fmt.source == "db")
		#expect(fmt.message == "retry \"connection\"")
		#expect(fmt.timestamp != nil)
		let header = parser.parse("\u{1B}[31m2026-10-11T12:34:56Z ERROR [api] unable to connect\u{1B}[0m")
		#expect(header.level == .error)
		#expect(header.source == "api")
		#expect(header.message == "unable to connect")
		#expect(header.timestamp != nil)
	}

	@Test func offlineModelFallbackAndStackFrames() {
		let parser = LogParser()
		let log = parser.parse("[Nest] 1234 - 10/11/2026, 12:34:56 PM ERROR [DatabaseService] Connection refused")
		#expect(log.isInferred)
		#expect(log.level == .error)
		#expect(log.message.contains("Connection refused"))
		let stack = "    at async connect (/app/main.ts:10:2)"
		#expect(parser.parse(stack).message == stack)
		#expect(parser.parse("plain output 🌍").message == "plain output 🌍")
		#expect(parser.parse(String(repeating: "x", count: 9000)).message.count == 9000)
	}

	@Test func partialChunksSeparateStreamsAndClear() {
		let store = LogStore(), service = UUID()
		store.append("INFO [api] con", serviceID: service, stream: .stdout)
		let original = store.entries[0].id
		store.append("ERROR fail\n", serviceID: service, stream: .stderr)
		store.append("nected\r\nnext\n", serviceID: service, stream: .stdout)
		#expect(store.entries.count == 3)
		#expect(store.entries[0].id == original)
		#expect(store.entries[0].parsed.message == "connected")
		#expect(store.entries[1].stream == .stderr)
		#expect(store.entries[1].parsed.level == .error)
		#expect(store.entries[2].raw == "next")
		store.finish(service)
		store.append("fresh", serviceID: service, stream: .stdout)
		#expect(store.entries.count == 4)
		store.clear(service)
		store.append("new", serviceID: service, stream: .stdout)
		#expect(store.entries.count == 1)
		#expect(store.entries[0].raw == "new")
	}

	@Test func boundedHistoryAndSearch() {
		let store = LogStore(), service = UUID()
		store.append((0..<1400).map { "INFO line \($0)" }.joined(separator: "\n") + "\n", serviceID: service)
		#expect(store.entries.count == LogStore.serviceLimit)
		#expect(store.entries.first?.raw == "INFO line 200")
		store.append(String(repeating: "z", count: 20_000), serviceID: service)
		let last = store.entries.last
		#expect(last?.raw.count == LogStore.lineLimit)
		let entry = store.entries[0]
		#expect(LogStore.matches(entry, query: "WEB feat/cockpit line", service: "Web", checkout: "project feat/cockpit"))
		#expect(!LogStore.matches(entry, query: "missing", service: "Web", checkout: "project"))
		#expect(LogScope.all.includes(entry))
		#expect(!LogScope.errors.includes(entry))
	}

	@Test func exportedJSONPreservesRawAndProvenance() throws {
		let store = LogStore(), service = UUID()
		let raw = #"{"level":"error","msg":"oops\nnext","logger":"db"}"#
		store.append(raw + "\n", serviceID: service, stream: .stderr)
		let exported = LogStore.export(store.entries, names: [service: "API"], json: true)
		#expect(exported.split(separator: "\n").count == 1)
		let record = try #require(try JSONSerialization.jsonObject(with: Data(exported.utf8)) as? [String: Any])
		#expect(record["raw"] as? String == raw)
		#expect(record["service"] as? String == "API")
		#expect(record["stream"] as? String == "stderr")
		#expect(record["inferred"] as? Bool == false)
	}
}
