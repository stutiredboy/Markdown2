import Foundation
import Testing
@testable import MD2App

struct EditorSourcePositionTests {
    @Test func indexesMixedLineBreaksGraphemesAndEdits() {
        let text = NSMutableString(string: "one\r\n\r👩🏽‍💻e\u{301}末\n")
        var index = EditorSourceIndex()
        #expect(index.position(at: text.length, in: text) == .init(line: 4, column: 1))
        let end = NSMaxRange(text.range(of: "e\u{301}"))
        #expect(index.position(at: end, in: text) == .init(line: 3, column: 3))
        text.insert("\n", at: 6) // Extend the bare CR after "one\r\n" to a CRLF pair.
        index.invalidate(from: 6)
        #expect(index.position(at: end + 1, in: text) == .init(line: 3, column: 3))
        text.replaceCharacters(in: NSRange(location: 0, length: 5), with: "")
        index.invalidate(from: 0)
        #expect(index.position(at: text.length, in: text) == .init(line: 3, column: 1))
    }

    @Test func deepMovesAndEditsPreserveColumnsAcrossUnicodeCheckpoints() {
        let token = "🇭🇰👩🏽‍💻é"
        let text = NSMutableString(string: String(repeating: token, count: 5000))
        var index = EditorSourceIndex()
        #expect(index.position(at: text.length, in: text) == .init(line: 1, column: 15_001))
        let end = token.utf16.count * 3000
        #expect(index.position(at: end, in: text) == .init(line: 1, column: 9001))
        text.insert("\n", at: end)
        index.invalidate(from: end)
        #expect(index.position(at: text.length, in: text) == .init(line: 2, column: 6001))
        #expect(index.position(at: end, in: text) == .init(line: 1, column: 9001))
    }
}
