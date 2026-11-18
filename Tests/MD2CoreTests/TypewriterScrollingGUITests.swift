import AppKit
import SwiftUI
import XCTest
@testable import MD2App

final class TypewriterScrollingGUITests: XCTestCase {
    @MainActor
    func testTypingAndArrowNavigationCenterTheNativeCaretInWrappedText() throws {
        let host = try TypewriterTestWindow()
        defer { host.close() }
        let editor = host.editor
        let original = editor.string
        let location = (original as NSString).range(of: "光标目标").location
        host.putCaretNearTop(location)

        let initial = host.scrollOffset
        host.press("x", keyCode: 7)
        XCTAssertEqual(editor.selectedRange(), NSRange(location: location + 1, length: 0))
        XCTAssertEqual(host.modelText, editor.string)
        XCTAssertGreaterThan(abs(host.scrollOffset - initial), 40)
        host.assertCaretCentered()
        try host.assertCaretRowCentered()
        host.spin(0.4)
        host.assertCaretCentered()

        host.putCaretNearTop(location + 1)
        host.press("\u{F701}", keyCode: 125) // Down Arrow
        XCTAssertGreaterThan(editor.selectedRange().location, location + 1)
        host.assertCaretCentered()
        try host.assertCaretRowCentered()
        XCTAssertTrue(host.session.undoManager.canUndo)
        host.session.undoManager.undo()
        XCTAssertEqual(host.modelText, original)
    }

    @MainActor
    func testTogglingAndSelectingLeaveTheViewportInPlace() throws {
        let host = try TypewriterTestWindow()
        defer { host.close() }
        let editor = host.editor
        let location = (editor.string as NSString).range(of: "光标目标").location
        host.coordinator.usesTypewriterScrolling = false
        host.putCaretNearTop(location)
        let initial = host.scrollOffset

        host.press("\u{F703}", keyCode: 124) // Right Arrow
        XCTAssertEqual(editor.selectedRange(), NSRange(location: location + 1, length: 0))
        XCTAssertEqual(host.scrollOffset, initial, accuracy: 1)
        XCTAssertGreaterThan(host.caretDistanceFromCenter, 40)

        host.coordinator.usesTypewriterScrolling = true
        XCTAssertEqual(host.scrollOffset, initial, accuracy: 1)
        editor.setSelectedRange(NSRange(location: location + 2, length: 0))
        XCTAssertEqual(host.scrollOffset, initial, accuracy: 1, "a programmatic caret change never centers")
        host.press("\u{F703}", keyCode: 124, modifiers: .shift)
        XCTAssertEqual(editor.selectedRange(), NSRange(location: location + 2, length: 1))
        XCTAssertEqual(host.scrollOffset, initial, accuracy: 1)

        host.scroll(to: initial + 31)
        host.spin()
        XCTAssertEqual(host.scrollOffset, initial + 31, accuracy: 1)
    }

    @MainActor
    func testResumingTypingRevealsAnOffscreenCaretAndLeavesLaterScrollingAlone() throws {
        let host = try TypewriterTestWindow()
        defer { host.close() }
        let editor = host.editor
        let location = (editor.string as NSString).range(of: "光标目标").location
        host.putCaretNearTop(location)
        host.scroll(to: 0)
        XCTAssertEqual(host.scrollOffset, 0, accuracy: 1)
        XCTAssertEqual(editor.selectedRange(), NSRange(location: location, length: 0))

        host.press("x", keyCode: 7)
        XCTAssertEqual(editor.selectedRange(), NSRange(location: location + 1, length: 0))
        try host.assertCaretRowCentered()

        host.scroll(to: 37)
        host.spin(0.45)
        XCTAssertEqual(host.scrollOffset, 37, accuracy: 1, "an older edit cannot restore over a later scroll")
    }

    @MainActor
    func testIMECompositionStaysInPlaceAndCommitCentersTheCaret() throws {
        let host = try TypewriterTestWindow()
        defer { host.close() }
        let editor = host.editor
        let original = editor.string
        let location = (original as NSString).range(of: "光标目标").location
        host.putCaretNearTop(location)
        let initial = host.scrollOffset
        let usesCurrentSelection = NSRange(location: NSNotFound, length: 0)

        editor.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0),
                             replacementRange: usesCurrentSelection)
        XCTAssertTrue(editor.hasMarkedText())
        XCTAssertEqual(host.modelText, original)
        XCTAssertEqual(host.scrollOffset, initial, accuracy: 1)

        // The input context can commit using insertText outside of keyDown.
        editor.insertText("拟", replacementRange: usesCurrentSelection)
        XCTAssertFalse(editor.hasMarkedText())
        XCTAssertEqual(editor.selectedRange(), NSRange(location: location + 1, length: 0))
        XCTAssertEqual(host.modelText, (original as NSString).replacingCharacters(
            in: NSRange(location: location, length: 0), with: "拟"))
        host.assertCaretCentered()
    }

    @MainActor
    func testClampsAtBothDocumentEdgesIncludingTheFinalEmptyRow() throws {
        let host = try TypewriterTestWindow()
        defer { host.close() }
        host.putCaretNearTop(0)
        host.press("\u{F703}", keyCode: 124)
        XCTAssertEqual(host.scrollOffset, 0, accuracy: 1)

        let end = try XCTUnwrap(host.editor.textStorage).length
        host.putCaretNearTop(end - 1)
        host.press("\u{F703}", keyCode: 124)
        XCTAssertEqual(host.editor.selectedRange(), NSRange(location: end, length: 0))
        let clip = host.scrollView.contentView
        var bottom = clip.bounds
        bottom.origin.y = host.editor.frame.maxY
        XCTAssertEqual(host.scrollOffset, clip.constrainBoundsRect(bottom).minY, accuracy: 1)
        XCTAssertLessThan(host.caretDistanceFromCenter, clip.bounds.height / 2)
    }
}

@MainActor
private final class TypewriterTestWindow {
    private(set) var modelText = String(repeating: "A bilingual paragraph with a soft wrap. 中文段落采用自动换行。 ", count: 48)
        + "光标目标。 " + String(repeating: "继续写作。 Keep writing. ", count: 64) + "\n\nEnd.\n"
    let session = MarkdownEditorSession()
    let scrollView: NSScrollView
    let window: NSWindow
    let editor: NSTextView
    lazy var coordinator = MarkdownEditorView.Coordinator(
        text: Binding(get: { [unowned self] in MainActor.assumeIsolated { modelText } },
                      set: { [unowned self] value in MainActor.assumeIsolated { modelText = value } }),
        session: session
    )

    init() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MD2_RUN_GUI_TESTS"] == "1",
                          "Set MD2_RUN_GUI_TESTS=1 to run native Typewriter Scrolling tests.")
        _ = NSApplication.shared
        let frame = NSRect(x: 0, y: 0, width: 470, height: 310)
        scrollView = NSScrollView(frame: frame)
        scrollView.hasVerticalScroller = true
        scrollView.contentView.postsBoundsChangedNotifications = true
        window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        editor = session.loadTextView(text: modelText)
        session.host(in: scrollView, coordinator: coordinator)
        coordinator.usesTypewriterScrolling = true
        coordinator.observe(scrollView: scrollView)
        window.contentView = scrollView
        window.makeKeyAndOrderFront(nil)
        XCTAssertTrue(window.makeFirstResponder(editor))
        MarkdownTextStyler.apply(to: editor)
        if let layoutManager = editor.layoutManager, let container = editor.textContainer {
            layoutManager.ensureLayout(for: container)
        }
        spin()
    }

    func close() {
        window.orderOut(nil)
        window.close()
    }

    func press(_ characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags = []) {
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                           timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                           characters: characters, charactersIgnoringModifiers: characters,
                                           isARepeat: false, keyCode: keyCode) else {
            XCTFail("could not construct key event")
            return
        }
        editor.keyDown(with: event)
        spin()
    }

    var scrollOffset: CGFloat { scrollView.contentView.bounds.minY }

    func scroll(to y: CGFloat) {
        let clip = scrollView.contentView
        var target = clip.bounds
        target.origin.y = y
        clip.scroll(to: clip.constrainBoundsRect(target).origin)
        scrollView.reflectScrolledClipView(clip)
    }

    func putCaretNearTop(_ location: Int) {
        let caret = NSRange(location: location, length: 0)
        editor.setSelectedRange(caret)
        editor.scrollRangeToVisible(caret)
        scroll(to: caretRect.midY - 56)
        spin()
    }

    private var caretRect: NSRect {
        editor.convert(window.convertFromScreen(editor.firstRect(forCharacterRange: editor.selectedRange(),
                                                                actualRange: nil)), from: nil)
    }

    var caretDistanceFromCenter: CGFloat { abs(caretRect.midY - scrollView.contentView.bounds.midY) }

    func assertCaretCentered(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertLessThan(caretDistanceFromCenter, 2, file: file, line: line)
    }

    func assertCaretRowCentered(file: StaticString = #filePath, line: UInt = #line) throws {
        let layout = try XCTUnwrap(editor.layoutManager, file: file, line: line)
        let glyph = layout.glyphIndexForCharacter(at: editor.selectedRange().location)
        let rowMidY = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).midY
            + editor.textContainerOrigin.y
        XCTAssertEqual(rowMidY, scrollView.contentView.bounds.midY, accuracy: 5, file: file, line: line)
    }

    func spin(_ duration: TimeInterval = 0.08) {
        let deadline = Date().addingTimeInterval(duration)
        while Date() < deadline { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
    }
}
