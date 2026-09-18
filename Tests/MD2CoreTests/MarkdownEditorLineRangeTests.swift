import Foundation
import Testing
@testable import MD2App
@testable import MD2Core

/// The fractional-line follow (smooth Side by Side scrolling) maps a 1-based
/// source line to its character range before measuring its on-screen rect.
/// These lock that mapping — the geometry layer can't be driven headless, but
/// its source-line arithmetic can.
struct MarkdownEditorLineRangeTests {
    private func range(_ line: Int, _ text: String) -> NSRange {
        MarkdownEditorView.Coordinator.characterRange(ofLine: line, in: text as NSString)
    }

    @Test func mapsEachLineToItsContentRange() {
        let text = "a\nbb\nccc"
        #expect(range(1, text) == NSRange(location: 0, length: 1)) // "a"
        #expect(range(2, text) == NSRange(location: 2, length: 2)) // "bb"
        #expect(range(3, text) == NSRange(location: 5, length: 3)) // "ccc"
    }

    @Test func emptyLineYieldsZeroLengthRangeAtItsStart() {
        let text = "a\n\nb"
        #expect(range(2, text) == NSRange(location: 2, length: 0))
    }

    @Test func lineNumbersAreClampedToValidStart() {
        let text = "x\ny"
        // Below range collapses to the first line.
        #expect(range(0, text) == NSRange(location: 0, length: 1))
        // Past the last line lands at the end with an empty range.
        #expect(range(9, text) == NSRange(location: 3, length: 0))
    }

    @Test func handlesTrailingNewline() {
        let text = "one\ntwo\n"
        #expect(range(1, text) == NSRange(location: 0, length: 3)) // "one"
        #expect(range(2, text) == NSRange(location: 4, length: 3)) // "two"
        // The empty line after the trailing newline.
        #expect(range(3, text) == NSRange(location: 8, length: 0))
    }
}

/// The Side by Side edit-follow keeps the caret's source line visible in the
/// preview while typing. It maps the caret's character index to a 1-based line
/// the same way `topVisibleLine` numbers scroll positions; these lock that
/// mapping so the preview follows the line the user is actually editing.
struct MarkdownEditorCaretLineTests {
    private func line(_ index: Int, _ text: String) -> Int {
        MarkdownEditorView.Coordinator.lineNumber(forCharacterIndex: index, in: text as NSString)
    }

    @Test func countsNewlinesBeforeTheCaret() {
        let text = "a\nbb\nccc"
        #expect(line(0, text) == 1) // before "a"
        #expect(line(1, text) == 1) // after "a", before the first newline
        #expect(line(2, text) == 2) // start of "bb"
        #expect(line(5, text) == 3) // start of "ccc"
        #expect(line(8, text) == 3) // end of text
    }

    @Test func caretAtStartOfEmptyLineCountsThatLine() {
        let text = "a\n\nb"
        #expect(line(2, text) == 2) // the empty middle line
        #expect(line(3, text) == 3) // start of "b"
    }

    @Test func clampsOutOfRangeIndices() {
        let text = "x\ny"
        #expect(line(-5, text) == 1)
        #expect(line(999, text) == 2) // last line, index clamped to length
    }

    @Test func caretAfterTrailingNewlineIsTheNewLine() {
        let text = "one\ntwo\n"
        #expect(line(8, text) == 3) // the empty line created by the trailing newline
    }
}

/// The gutter numbers one row per *source* line: a fragment that begins a line is
/// numbered, a fragment that continues a soft-wrapped line is not. Numbering uses
/// the renderer's line-break convention so the editor gutter and the preview's
/// block numbers agree, including on bare-CR files.
struct MarkdownEditorGutterRowTests {
    private func rows(_ starts: [Int], _ text: String) -> [Int?] {
        MarkdownEditorView.Coordinator.gutterRows(forFragmentStarts: starts, in: text as NSString)
    }

    @Test func numbersEachLineFromItsFragmentStart() {
        #expect(rows([0, 2, 5], "a\nbb\nccc") == [1, 2, 3])
    }

    @Test func wrappedContinuationFragmentsGetNoNumber() {
        // One source line soft-wrapped into three visual rows: the later two
        // fragments are the same source line and must stay unnumbered.
        let long = String(repeating: "x", count: 240)

        #expect(rows([0, 80, 160], long) == [1, nil, nil])
    }

    @Test func numberingResumesAfterAWrappedLine() {
        // 200 characters (offsets 0...199), the newline at 200, so the second
        // source line begins at 201.
        let text = String(repeating: "x", count: 200) + "\nnext"

        #expect(rows([0, 80, 201], text) == [1, nil, 2])
    }

    @Test func trailingNewlineNumbersTheEmptyLastLine() {
        // Parity with the status bar, find, and the outline: a document ending in
        // a newline has a final empty line, and the extra line fragment that
        // TextKit reports for it carries a number.
        #expect(rows([0, 4, 8], "one\ntwo\n") == [1, 2, 3])
    }

    @Test func emptyDocumentNumbersItsSingleLine() {
        #expect(rows([0], "") == [1])
    }

    @Test func crlfLineBreaksNumberAsOneBreakEach() {
        #expect(rows([0, 3, 6], "a\r\nb\r\nc") == [1, 2, 3])
    }

    @Test func bareCarriageReturnsNumberAsOneBreakEach() {
        #expect(rows([0, 2, 4], "a\rb\rc") == [1, 2, 3])
    }

    @Test func fragmentStartInsideACRLFPairIsNotALineStart() {
        // A CRLF straddling the gap must count as one break, and a start landing
        // between the CR and the LF is not the beginning of a line.
        #expect(rows([0, 2], "a\r\nb") == [1, nil])
        #expect(rows([0, 2, 3], "a\r\nb") == [1, nil, 2])
    }

    @Test func outOfOrderStartsAreTreatedAsContinuations() {
        // Defensive: a non-monotonic caller must not corrupt the running count.
        #expect(rows([5, 0, 7], "a\nbb\nccc") == [3, nil, nil])
    }

    /// Every character offset at which a line begins, under the convention the
    /// renderer uses to number blocks (LF, CRLF, and bare CR are one break each).
    private func lineStarts(in text: String) -> [Int] {
        let ns = text as NSString
        var starts = [0]
        var index = 0
        while index < ns.length {
            let character = ns.character(at: index)
            if character == 0x0A {
                index += 1
                starts.append(index)
            } else if character == 0x0D {
                index += (index + 1 < ns.length && ns.character(at: index + 1) == 0x0A) ? 2 : 1
                starts.append(index)
            } else {
                index += 1
            }
        }
        return starts
    }

    @Test func highestNumberMatchesTheRenderersLineCount() {
        // The contract the preview shares: the last number the gutter can show is
        // the number of lines the renderer itself sees, so the editor and the
        // preview agree on every document. The expected value comes from the
        // renderer's own splitter, not from this file's convention.
        let documents = [
            "a\nbb\nccc",
            "one\ntwo\n",
            "\n\n\n",
            "a\r\nb\r\nc",
            "a\rb\rc",
            "",
            "\n",
            "x",
            String(repeating: "x", count: 240) + "\ntail"
        ]

        for document in documents {
            let numbered = rows(lineStarts(in: document), document).compactMap { $0 }

            #expect(
                numbered.last == document.normalizedMarkdownLines.count,
                "\(document.debugDescription) → \(numbered)"
            )
        }
    }
}
