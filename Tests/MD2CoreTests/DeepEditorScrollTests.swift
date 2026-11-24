import AppKit
import MD2Core
import SwiftUI
import Testing
@testable import MD2App

@Suite(.serialized)
@MainActor
struct DeepEditorScrollTests {
    @Test func restoredWrappedPositionKeepsSelectionWithoutLayingOutTheTail() async throws {
        let fixture = try EditorFixture()
        let original = fixture.host(width: 640)
        fixture.layout.ensureLayout(for: fixture.container)
        let paragraph = MarkdownEditorView.Coordinator.characterRange(
            ofLine: 1_203, in: fixture.storage.string as NSString
        )
        let wrappedRow = paragraph.location + 160
        let workingSelection = NSRange(location: wrappedRow + 11, length: 6)
        fixture.editor.setSelectedRange(workingSelection)
        let originalY = fixture.rowTop(at: wrappedRow) + 4
        original.scrollView.contentView.scroll(to: NSPoint(x: 0, y: originalY))
        let anchor = try #require(MarkdownEditorView.Coordinator.viewportAnchor(in: original.scrollView))
        let position = try #require(anchor.editorPosition)
        #expect(position.characterIndex > 50_000)
        let targetWidth: CGFloat = 470
        let target = fixture.host(width: targetWidth)
        fixture.invalidateLayout()

        // Test the actual anchor restore and settle path. Its top-line
        // report and the restored viewport both have to use scoped layout.
        try await fixture.restore(anchor, at: target)
        let laidOut = fixture.layout.firstUnlaidCharacterIndex()
        #expect(laidOut > wrappedRow)
        #expect(laidOut < fixture.storage.length)
        #expect(fixture.editor.selectedRange() == workingSelection)
        let restoredY = target.scrollView.contentView.bounds.minY
        try fixture.drawVisibleEditorWithGutter()
        #expect(fixture.layout.firstUnlaidCharacterIndex() < fixture.storage.length,
                "the first paint with line numbers must not lay out the tail")

        fixture.layout.ensureLayout(for: fixture.container)
        let exactY = fixture.rowTop(at: position.characterIndex) + CGFloat(position.verticalOffset)
        #expect(abs(restoredY - exactY) < 1)
        #expect(abs(restoredY - originalY) > 100, "fixture must rewrap at the new width")
        #expect(!fixture.editor.visibleRect.isEmpty)
    }

    @Test func outlineAndFractionalLineJumpsKeepAnInteriorViewportExact() throws {
        let fixture = try EditorFixture()
        let host = fixture.host(width: 520)
        let line = 1_199
        fixture.invalidateLayout()
        #expect(fixture.apply(.init(sourceLine: line), at: host, initializesCaret: true))
        let location = MarkdownEditorView.Coordinator.characterRange(ofLine: line, in: fixture.storage.string as NSString).location
        #expect(fixture.editor.selectedRange() == NSRange(location: location, length: 0))
        #expect(fixture.layout.firstUnlaidCharacterIndex() < fixture.storage.length)
        let outlineY = host.scrollView.contentView.bounds.minY

        fixture.invalidateLayout()
        let followY = try #require(MarkdownEditorView.Coordinator.clipTargetY(
            forFractionalLine: Double(line) + 0.375, in: host.scrollView
        ))
        #expect(fixture.layout.firstUnlaidCharacterIndex() < fixture.storage.length)

        fixture.layout.ensureLayout(for: fixture.container)
        let glyphs = fixture.layout.glyphRange(
            forCharacterRange: NSRange(location: location, length: 0), actualCharacterRange: nil
        )
        let exactOutlineY = fixture.layout.boundingRect(forGlyphRange: glyphs, in: fixture.container).minY
        #expect(abs(outlineY - exactOutlineY) < 1)
        let lineRect = try #require(MarkdownEditorView.Coordinator.lineBoundingRect(line: line, in: fixture.editor))
        #expect(abs(followY - (lineRect.minY + 0.375 * lineRect.height)) < 1)
    }

    @Test func aProvisionalClipViewCannotConsumeTheRestoredAnchor() async throws {
        let fixture = try EditorFixture(sectionCount: 40)
        let provisionalClip = ProvisionalEditorClipView()
        let host = fixture.host(width: 520, clipView: provisionalClip)
        let line = MarkdownEditorView.Coordinator.characterRange(
            ofLine: 123, in: fixture.storage.string as NSString
        )
        let anchor = ViewportAnchor(editorPosition: .init(characterIndex: line.location, verticalOffset: 4))

        let appliedBeforeLayout = fixture.apply(anchor, at: host)
        #expect(!appliedBeforeLayout)
        #expect(provisionalClip.bounds.minY <= 24)

        var appliedAttempts = 0
        var settled: ViewportAnchor?
        host.scrollView.onLayout = { host.coordinator.scheduleAnchorRestore(in: host.scrollView) }
        host.coordinator.applyAnchorUntilSettled(anchor, in: host.scrollView, onSettled: { settled = $0 }) { anchor, _ in
            appliedAttempts += 1
            return fixture.apply(anchor, at: host)
        }
        try await Task.sleep(for: .milliseconds(20))
        #expect(appliedAttempts == 0)

        let window = fixture.mount(host)
        defer {
            window.contentView = nil
            host.scrollView.onLayout = nil
            host.coordinator.cancelAnchorRestore()
        }
        for _ in 0..<100 where appliedAttempts == 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(appliedAttempts > 0)
        #expect(settled == nil, "the mounted clip still rejects the deep offset")

        provisionalClip.canReachAnchor = true
        host.scrollView.needsLayout = true
        host.scrollView.layoutSubtreeIfNeeded()
        for _ in 0..<100 where settled == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(settled == anchor)
        #expect(abs(provisionalClip.bounds.minY - (fixture.rowTop(at: line.location) + 4)) < 1)
    }

    @Test func bottomClampAndFractionFallbackUseTheExactHeightAfterResizeOrShrink() throws {
        let fixture = try EditorFixture()
        let host = fixture.host(width: 450)
        let selection = NSRange(location: 4, length: 0)
        fixture.editor.setSelectedRange(selection)

        let endAnchor = ViewportAnchor(editorPosition: .init(characterIndex: fixture.storage.length - 1,
                                                             verticalOffset: 0))
        fixture.invalidateLayout()
        #expect(fixture.apply(endAnchor, at: host))
        #expect(fixture.layout.firstUnlaidCharacterIndex() == fixture.storage.length)
        #expect(abs(host.scrollView.contentView.bounds.minY - fixture.exactBottom(in: host)) < 1)

        host.scrollView.setFrameSize(NSSize(width: 680, height: 420))
        host.scrollView.tile()
        fixture.invalidateLayout()
        #expect(fixture.apply(.init(scrollFraction: 0.42), at: host))
        #expect(fixture.layout.firstUnlaidCharacterIndex() == fixture.storage.length)
        #expect(abs(host.scrollView.contentView.bounds.minY - 0.42 * fixture.exactBottom(in: host)) < 1)
        #expect(fixture.editor.selectedRange() == selection)

        #expect(fixture.session.resetText(to: "Short line\nLast line\n"))
        let selectionAfterShrink = fixture.editor.selectedRange()
        fixture.invalidateLayout()
        // Resolve a nonzero requested offset, including the trailing newline.
        let shortAnchor = ViewportAnchor(editorPosition: .init(characterIndex: fixture.storage.length - 1,
                                                               verticalOffset: 12))
        #expect(fixture.apply(shortAnchor, at: host))
        #expect(host.scrollView.contentView.bounds.minY == 0)
        #expect(fixture.editor.selectedRange() == selectionAfterShrink)
    }
}

/// The native clip view can accept a scroll request before the new editor
/// host's document bounds permit scrolling that far.
private final class ProvisionalEditorClipView: NSClipView {
    var canReachAnchor = false

    override func scroll(to newOrigin: NSPoint) {
        let y = canReachAnchor ? newOrigin.y : min(newOrigin.y, 24)
        super.scroll(to: NSPoint(x: newOrigin.x, y: y))
    }
}

@MainActor
private final class EditorFixture {
    typealias Host = (scrollView: MarkdownEditorScrollView, coordinator: MarkdownEditorView.Coordinator)

    let session = MarkdownEditorSession()
    let editor: NSTextView
    let layout: NSLayoutManager
    let container: NSTextContainer
    let storage: NSTextStorage
    let view: MarkdownEditorView

    init(sectionCount: Int = 1_100) throws {
        let paragraph = "A bilingual draft with **edits**, 中文自动换行 and meaningful details. "
        let source = String(repeating: "# Notes\n\n" + String(repeating: paragraph, count: 4) + "\n\n", count: sectionCount)
        editor = session.loadTextView(text: source)
        layout = try #require(editor.layoutManager)
        container = try #require(editor.textContainer)
        storage = try #require(editor.textStorage)
        layout.backgroundLayoutEnabled = false
        view = MarkdownEditorView(text: .constant(source), jumpLine: .constant(nil), jumpFraction: .constant(nil),
                                  jumpAnchor: .constant(nil), findQuery: .constant(""), findNavigation: .constant(nil),
                                  findReplacement: .constant(""), replaceCommand: .constant(nil), focusToken: nil,
                                  lineSelection: .constant(nil), session: session)
    }

    func host(width: CGFloat, clipView: NSClipView? = nil) -> Host {
        let scrollView = MarkdownEditorScrollView(frame: NSRect(x: 0, y: 0, width: width, height: 290))
        if let clipView { scrollView.contentView = clipView }
        let coordinator = view.makeCoordinator()
        session.host(in: scrollView, coordinator: coordinator)
        // Apply distinct glyph metrics for headers and inline emphasis, as a
        // live editor does, before explicitly invalidating the layout cache.
        MarkdownTextStyler.apply(to: editor)
        return (scrollView, coordinator)
    }

    func invalidateLayout() {
        layout.invalidateLayout(forCharacterRange: NSRange(location: 0, length: storage.length),
                                actualCharacterRange: nil)
    }

    func apply(_ anchor: ViewportAnchor, at host: Host, initializesCaret: Bool = false) -> Bool {
        view.apply(anchor: anchor, in: host.scrollView, textView: editor,
                   focus: false, initializesCaret: initializesCaret)
    }

    func mount(_ host: Host) -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: host.scrollView.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = host.scrollView
        return window
    }

    func restore(_ anchor: ViewportAnchor, at host: Host) async throws {
        let window = mount(host)
        defer { window.contentView = nil }

        var settled = false
        host.coordinator.onAnchorLineChange = { _, drivesPreviewSync in settled = drivesPreviewSync }
        host.coordinator.applyAnchorUntilSettled(anchor, in: host.scrollView) { [self] _, _ in
            apply(anchor, at: host)
        }
        for _ in 0..<100 where !settled {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(settled)
        host.coordinator.onAnchorLineChange = { _, _ in }
    }

    func rowTop(at character: Int) -> CGFloat {
        let glyph = layout.glyphIndexForCharacter(at: character)
        return layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY
    }

    func exactBottom(in host: Host) -> CGFloat {
        max(0, ceil(layout.usedRect(for: container).maxY + 2 * editor.textContainerInset.height)
            - host.scrollView.contentView.bounds.height)
    }

    func drawVisibleEditorWithGutter() throws {
        let editor = try #require(editor as? MarkdownSourceTextView)
        let rect = editor.visibleRect
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(rect.width.rounded(.up)),
                                                   pixelsHigh: Int(rect.height.rounded(.up)), bitsPerSample: 8,
                                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                                   bytesPerRow: 0, bitsPerPixel: 0))
        let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        let transform = NSAffineTransform()
        transform.translateX(by: -rect.minX, yBy: -rect.minY)
        transform.concat()
        editor.showsLineNumbers = true
        editor.draw(rect)
    }
}
