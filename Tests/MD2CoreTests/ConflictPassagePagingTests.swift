import Testing
@testable import MD2App

struct ConflictPassagePagingTests {
    @Test func allPagesReconstructThePassageAcrossUnicodeAndLineBreaks() {
        let source = String(repeating: "段👩🏽‍💻", count: 930)
            + String(repeating: "\r\n", count: 110) + "e" + String(repeating: "\u{301}", count: 2050)
        var next: String.Index? = source.startIndex
        var pages: [String] = []
        while let start = next {
            let page = ConflictPassagePage(source: source, start: start)
            #expect(!page.text.isEmpty)
            #expect(page.text.unicodeScalars.count <= 2048)
            #expect(page.text.unicodeScalars.filter { $0 == "\r" || $0 == "\n" }.count <= 40)
            pages.append(page.text)
            next = page.next
        }
        #expect(pages.count > 4)
        #expect(pages.joined().utf8.elementsEqual(source.utf8))
    }
}
