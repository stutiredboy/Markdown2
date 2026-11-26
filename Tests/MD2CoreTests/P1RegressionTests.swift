import AppKit
import Foundation
import Testing
@testable import MD2Core
@testable import MD2App

@Suite(.serialized)
struct P1RegressionTests {
    @Test func rawHTMLCannotCarryExecutableOrApplicationAttributes() {
        let body = MarkdownRenderer().render(#"<img src="missing.png" onerror="window.pwned=1" style="position:fixed" data-md2-task-line="1"><details open ontoggle="window.pwned=2"><summary>Safe</summary><b title="ok">text</b></details>"#).body
        #expect(!body.contains("onerror="))
        #expect(!body.contains("ontoggle="))
        #expect(!body.contains("style="))
        #expect(!body.contains("data-md2-task-line="))
        #expect(body.contains(#"src="missing.png""#))
        #expect(body.contains(#"<b title="ok">text</b>"#))
        #expect(body.contains(#"<details open data-md2-source-line="1">"#))
    }

    @Test(arguments: ["javascript&#58;void%200", "java&#x73;cript:alert", "java&Tab;script:alert", "data:text/html,test", "vbscript:alert"])
    func encodedActiveURLsAreInert(_ url: String) {
        let body = MarkdownRenderer().render("[label](\(url)) ![image](\(url)) <img src=\"\(url)\">").body
        #expect(!body.contains("<a href="))
        #expect(!body.contains("<img src="))
        #expect(body.contains("label"))
    }

    @Test @MainActor func unclosedBracketsHaveBoundedCost() {
        // An absolute generous ceiling avoids flaky ratios on sub-millisecond
        // runs. Before the fix, 20K brackets take >4 seconds even in release.
        let text = String(repeating: "[", count: 20_000)
        let view = NSTextView()
        view.string = text
        let start = ContinuousClock.now
        let result = MarkdownRenderer().render(text)
        MarkdownTextStyler.apply(to: view)
        #expect(start.duration(to: .now) < .seconds(1))
        #expect(result.body.contains(text))
    }

    @Test @MainActor func rehostDoesNotWrapAtAnUnmeasuredWidth() {
        let source = String(repeating: "A paragraph with 中文 source text.\n\n", count: 50)
        let session = MarkdownEditorSession()
        let editor = session.loadTextView(text: source)
        let previous = MarkdownEditorScrollView(frame: NSRect(x: 0, y: 0, width: 520, height: 240))
        let previousCoordinator = MarkdownEditorView.Coordinator(text: .constant(source), session: session)
        session.host(in: previous, coordinator: previousCoordinator)
        let previousWidth = editor.frame.width
        #expect(previousWidth > 0)
        editor.setSelectedRange(NSRange(location: 12, length: 3))

        let destination = MarkdownEditorScrollView(frame: .zero)
        let destinationCoordinator = MarkdownEditorView.Coordinator(text: .constant(source), session: session)
        session.host(in: destination, coordinator: destinationCoordinator)
        #expect(previous.documentView == nil)
        #expect(destination.documentView === editor)
        #expect(editor.frame.width == previousWidth)
        #expect(editor.selectedRange() == NSRange(location: 12, length: 3))

        destination.setFrameSize(NSSize(width: 700, height: 320))
        destination.tile()
        destination.layout()
        #expect(editor.frame.width == destination.contentSize.width)
        #expect(editor.autoresizingMask.contains(.width))
        #expect(editor.selectedRange() == NSRange(location: 12, length: 3))

        let sourceEditor = editor as? MarkdownSourceTextView
        sourceEditor?.typography = TypographySettings(fontSize: 32, zoom: 2)
        destination.setFrameSize(NSSize(width: DocumentLayoutMetrics.splitEditorMinWidth, height: 320))
        destination.tile()
        destination.layout()
        #expect(editor.frame.width == destination.contentSize.width)
        #expect(editor.textContainerInset.width * 2 < editor.frame.width)
    }

    @Test @MainActor func topAnchorLeavesTheDocumentTailUnlaid() throws {
        let section = "Markdown paragraph with English and 中文. Another short sentence.\n\n"
        let storage = NSTextStorage(string: String(repeating: section, count: 3_000),
                                    attributes: [.font: NSFont.systemFont(ofSize: 16)])
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude))
        layout.addTextContainer(container)
        let frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        let editor = NSTextView(frame: frame, textContainer: container)
        editor.isVerticallyResizable = true
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        let scroll = NSScrollView(frame: frame)
        scroll.documentView = editor
        layout.invalidateLayout(forCharacterRange: NSRange(location: 0, length: storage.length), actualCharacterRange: nil)
        try #require(layout.firstUnlaidCharacterIndex() < storage.length)

        let anchor = try #require(MarkdownEditorView.Coordinator.viewportAnchor(in: scroll))
        #expect(anchor.sourceLine == 1)
        #expect(anchor.scrollFraction == 0)
        #expect(anchor.editorPosition?.characterIndex == 0)
        #expect(layout.firstUnlaidCharacterIndex() < storage.length)
    }

    @Test @MainActor func retainedStylingReappliesOnlyAfterSourceChanges() async {
        let session = MarkdownEditorSession()
        let editor = session.loadTextView(text: "# Heading\n\n**Before**")
        var applies = 0
        func style() async {
            session.styling.schedule(in: editor, sourceRevision: { session.structuredSourceRevision },
                                     willApply: { applies += 1 })
            await session.styling.flush()
        }

        await style()
        let initialCount = applies
        #expect(initialCount > 0)
        await style()
        #expect(applies == initialCount)
        editor.textStorage?.replaceCharacters(in: NSRange(location: 11, length: 10), with: "`After`")
        await style()
        #expect(applies > initialCount)

        let reference = NSTextView()
        reference.string = editor.string
        MarkdownTextStyler.apply(to: reference)
        #expect(editor.textStorage?.isEqual(to: reference.textStorage!) == true)
    }

    @Test @MainActor func renderingYieldsMainActorAndLatestRevisionWins() async throws {
        let store = DocumentStore()
        let chunk = "## 标题 Example\n\n中文 **bold** and `code`.\n\n- item one\n- item two\n\n"
        store.text = String(repeating: chunk, count: 4_000)
        let start = ContinuousClock.now
        let heartbeat = Task { @MainActor in
            try await Task.sleep(for: .milliseconds(10))
            return start.duration(to: .now)
        }
        await store.flushPendingRender()
        let latency = try await heartbeat.value
        #expect(latency < .milliseconds(200))
        print("P1 render main_actor_heartbeat_ms=\(Self.milliseconds(latency)) total_ms=\(Self.milliseconds(start.duration(to: .now)))")

        // Let an obsolete render actually start, then replace it twice.
        store.text += "old work"
        store.renderImmediately()
        try await Task.sleep(for: .milliseconds(10))
        store.text = "# Intermediate"
        store.text = "# Newest\n\nLatest content."
        await store.flushPendingRender()
        #expect(store.rendered.outline.map(\.title) == ["Newest"])
        #expect(!store.rendered.body.contains("old work"))
    }

    @Test @MainActor func incrementalStylingMatchesFullStylingAcrossStructuralEdits() async {
        let fixtures: [(String, NSRange, String)] = [
            ("# 标题\n\nparagraph text\n\n**bold**", NSRange(location: 15, length: 0), "🙂中文"),
            ("```swift\nlet x = 1\n```\n# after\n", NSRange(location: 18, length: 3), ""),
            ("paragraph\n\n# heading\n", NSRange(location: 0, length: 0), "```\n"),
            ("**first\nsecond**\n\ntail", NSRange(location: 0, length: 2), ""),
            ("# heading\r\nnext\r\n", NSRange(location: 0, length: 2), ""),
            ("# heading", NSRange(location: 0, length: 9), "")
        ]
        for (text, range, replacement) in fixtures {
            let view = NSTextView()
            view.isRichText = false
            view.string = text
            let controller = MarkdownStylingController()
            controller.schedule(in: view)
            await controller.flush()
            view.textStorage!.replaceCharacters(in: range, with: replacement)
            let selection = NSRange(location: range.location + (replacement as NSString).length, length: 0)
            view.setSelectedRange(selection)
            controller.schedule(in: view)
            await controller.flush()
            let reference = NSTextView()
            reference.string = view.string
            MarkdownTextStyler.apply(to: reference)
            #expect(view.textStorage!.isEqual(to: reference.textStorage!))
            #expect(view.selectedRange() == selection)
        }
    }

    @Test func ordinaryEditInvalidatesOnlyItsParagraph() {
        let text = String(repeating: "## Heading\n\nplain paragraph **bold**\n\n", count: 3_000)
        let previous = MarkdownStylePlan(text)
        let edited = (text as NSString).replacingCharacters(in: NSRange(location: 50_000, length: 0), with: "x")
        let plan = MarkdownStylePlan(edited)
        #expect(plan.changedRange(from: previous).length < 100)
    }

    @Test @MainActor func inputDuringChunkedStylingSupersedesTheOldPlan() async {
        let view = NSTextView()
        view.string = String(repeating: "# Heading\n\nparagraph\n\n", count: 2_000)
        let controller = MarkdownStylingController()
        var replaced = false
        controller.schedule(in: view, didApply: {
            guard !replaced else { return }
            replaced = true
            view.string = "## Newest 中文🙂"
            controller.schedule(in: view)
        })
        await controller.flush()
        let reference = NSTextView()
        reference.string = "## Newest 中文🙂"
        MarkdownTextStyler.apply(to: reference)
        #expect(replaced)
        #expect(view.textStorage!.isEqual(to: reference.textStorage!))
    }

    @Test @MainActor func pendingStyleDoesNotOverwriteIMEComposition() async {
        let view = NSTextView()
        view.string = "# heading"
        let controller = MarkdownStylingController()
        controller.schedule(in: view)
        view.setSelectedRange(NSRange(location: 9, length: 0))
        view.setMarkedText(NSAttributedString(string: "wubi", attributes: [.font: NSFont.systemFont(ofSize: 31)]),
            selectedRange: NSRange(location: 4, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        let marked = view.markedRange()
        view.textStorage?.addAttribute(.font, value: NSFont.systemFont(ofSize: 31), range: marked)
        await controller.flush()
        #expect(view.hasMarkedText())
        #expect(view.markedRange() == marked)
        #expect((view.textStorage?.attribute(.font, at: marked.location, effectiveRange: nil) as? NSFont)?.pointSize == 31)
    }

    @Test @MainActor func pendingStyleRejectsCanonicallyEqualSourceMutation() async throws {
        let original = "**a\u{0301}\u{0323}**"
        let changed = "**a\u{0323}\u{0301}**"
        try #require(original == changed && !original.utf16.elementsEqual(changed.utf16))
        let view = NSTextView()
        view.string = original
        let controller = MarkdownStylingController()
        var didStyleOldSource = false
        controller.schedule(in: view, didApply: { didStyleOldSource = true })
        view.string = changed

        await controller.flush()

        #expect(!didStyleOldSource)
        #expect(view.string.utf16.elementsEqual(changed.utf16))
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
    }
}
