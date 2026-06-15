import Foundation
import Testing
@testable import MD2App

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
