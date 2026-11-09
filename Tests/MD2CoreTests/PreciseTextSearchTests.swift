import Foundation
import Testing
@testable import MD2Core
@testable import MD2App

struct PreciseTextSearchTests {
    @Test func caseSensitivityDoesNotDisableAccentFolding() {
        let text = "café CAFE Cafe\u{301}"
        #expect(TextSearch.matches(of: "cafe", in: text).count == 3)
        #expect(TextSearch.matches(of: "cafe", in: text, options: .init(caseSensitive: true)) == [NSRange(location: 0, length: 4)])
        #expect(TextSearch.matches(of: "Cafe", in: text, options: .init(caseSensitive: true)) == [NSRange(location: 10, length: 5)])
    }

    @Test func wholeWordUsesUnicodeRunsRatherThanAsciiBoundaries() {
        let options = TextSearch.Options(wholeWord: true)
        #expect(TextSearch.matches(of: "cat", in: "cat scatter cat_ cat2 cat—cat", options: options).count == 3)
        #expect(TextSearch.matches(of: "中文", in: "中文 中文测试 中文_ 中文2 （中文）", options: options).count == 2)
        #expect(TextSearch.matches(of: "cafe", in: "cafe\u{301} cafe\u{301}ine", options: options) == [NSRange(location: 0, length: 5)])
    }

    @Test func matchesNeverSplitGraphemesIncludingEmoji() {
        #expect(TextSearch.matches(of: "👩", in: "👩‍💻 👩🏽 👩") == [NSRange(location: 11, length: 2)])
        #expect(TextSearch.matches(of: "🇺", in: "🇺🇸").isEmpty)
        #expect(TextSearch.matches(of: "\r", in: "a\r\nb").isEmpty)
        #expect(TextSearch.matches(of: "👩‍💻", in: "x👩‍💻y", options: .init(wholeWord: true)) == [NSRange(location: 1, length: 5)])
    }

    @Test func scopesUseUtf16AndNeverCreateWordBoundaries() {
        let text = "😀猫猫 cat dog"
        #expect(TextSearch.matches(of: "猫", in: text, scope: NSRange(location: 2, length: 1)) == [NSRange(location: 2, length: 1)])
        #expect(TextSearch.matches(of: "猫", in: text, options: .init(wholeWord: true), scope: NSRange(location: 2, length: 1)).isEmpty)
        for range in [NSRange(location: 0, length: 0), NSRange(location: 1, length: 1), NSRange(location: NSNotFound, length: 1), NSRange(location: 1, length: Int.max)] {
            #expect(TextSearch.matches(of: "😀", in: text, scope: range).isEmpty)
        }
    }

    @Test func previewSharesCoreUnicodeAndStopsAtBudgets() {
        #expect(PreviewTextSearch.ranges(query: "cafe", text: "😀 CAFÉ cafe\u{301}", options: .init(caseSensitive: true)) == [[8, 5]])
        #expect(PreviewTextSearch.ranges(query: "a", text: String(repeating: "a", count: PreviewTextSearch.maximumMatches + 1), options: .init()) == nil)
        #expect(PreviewTextSearch.ranges(query: "a", text: String(repeating: "x", count: PreviewTextSearch.maximumUTF16 + 1), options: .init()) == nil)
    }
}
