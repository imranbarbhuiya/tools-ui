import Foundation
import Testing
@testable import ToolsUI

@Test func unicodeChunks() {
	var decoder = UTF8StreamDecoder()
	let bytes = Array("hello 🌍".utf8)
	#expect(decoder.append(Data(bytes.prefix(8))) == "hello ")
	#expect(decoder.append(Data(bytes.suffix(2))) == "🌍")
}
