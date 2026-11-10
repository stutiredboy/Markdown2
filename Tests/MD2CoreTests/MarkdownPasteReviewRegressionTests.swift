import AppKit
import Testing
@testable import MD2App
@testable import MD2Core

struct MarkdownPasteConversionReviewRegressionTests {
    @Test(arguments: [
        (#"{\rtf1\uc1 \u65\tab B}"#, "AB"),
        (#"{\rtf1\uc1 \u65\~B}"#, "AB"),
        (#"{\rtf1\uc1 \u65\_B}"#, "AB"),
        (#"{\rtf1\uc1 \u65\{B}"#, "AB"),
        (#"{\rtf1\uc1 \u65\\B}"#, "AB"),
        (#"{\rtf1\uc1 \u65\'3fB}"#, "AB"),
        (#"{\rtf1\uc1 \u65\b B}"#, "AB"),
        (#"{\rtf1\uc1 \u65{B}C}"#, "ABC"),
        (#"{\rtf1\uc2 \u65?{B}C}"#, "ABC"),
        (#"{\rtf1\uc2 {\u65?}B}"#, "AB"),
        (#"{\rtf1\uc1 \u65\bin3 abcB}"#, "AB")
    ])
    func pC1UnicodeFallbackConsumesTokensNotFollowingText(_ rtf: String, _ expected: String) throws {
        let output = try MarkdownPaste.convert(.markdown, payload: .init(rtf: Data(rtf.utf8))).get()
        #expect(output.fallbackReason == nil)
        let body = MarkdownRenderer().render(output.text).body
        #expect(RenderedPlainText.extract(from: body) == expected)
        #expect(!body.contains("<strong>"), "a skipped fallback formatting control must have no effect")
    }
    @Test(arguments: [
        "<p>A<title>B</title>C</p>", "<body>A<title>B</title>C</body>", "<title>B</title>",
        "<p>A<head><title>B</title></head>C</p>", "<p>A<html><head><title>B</title></head></html>C</p>",
        "<head>B</head>", "<head><p>B</p></head>", "<p>A</p><html><head><title>B</title></head></html>C",
        "<head><title><b>B</b></title></head>"
    ])
    func pC2HTMLMetadataMustBeInHead(_ html: String) throws {
        let output = try MarkdownPaste.convert(.markdown, payload: .init(plainText: "A B C", html: Data(html.utf8))).get()
        #expect(output.fallbackReason != nil)
        #expect(RenderedPlainText.extract(from: MarkdownRenderer().render(output.text).body) == "A B C")
        #expect(throws: MarkdownPaste.Failure.self) { try MarkdownPaste.convert(.markdown, payload: .init(html: Data(html.utf8))).get() }
    }
    @Test(arguments: [#"{\rtf1 A{\fonttbl B}C}"#, #"{\rtf1 A{\colortbl B}C}"#, #"{\rtf1 A{\*\generator B}C}"#, #"{\rtf1 {\b {\fonttbl B}}C}"#, #"{\rtf1 A{\*\b B}C}"#, #"{\rtf1 A{\*\ansi B}C}"#, #"{\rtf1{\*\b B}}"#, #"{\rtf1{\*\ansi B}}"#])
    func pC2C3MisplacedOrUnknownRTFDestinationsRejectWholeInput(_ rtf: String) throws {
        let output = try MarkdownPaste.convert(.markdown, payload: .init(plainText: "A B C", rtf: Data(rtf.utf8))).get()
        #expect(output.fallbackReason != nil)
        #expect(RenderedPlainText.extract(from: MarkdownRenderer().render(output.text).body) == "A B C")
        #expect(throws: MarkdownPaste.Failure.self) { try MarkdownPaste.convert(.markdown, payload: .init(rtf: Data(rtf.utf8))).get() }
    }
    @Test func inertVoidMetaStillConvertsButActiveAttributesReject() throws {
        let output = try MarkdownPaste.convert(.markdown, payload: .init(html: Data("<meta charset='utf-8'><b>A</b>".utf8))).get()
        #expect(output.fallbackReason == nil)
        #expect(MarkdownRenderer().render(output.text).body.contains("<strong>A</strong>"))
        for meta in ["<meta http-equiv='refresh' content='0; url=https://example.com'>", "<meta src='file:///tmp/secret'>", "<meta onload='bad()'>", "<meta style='background:url(https://example.com)'>"] {
            let rejected = try MarkdownPaste.convert(.markdown, payload: .init(plainText: "visible", html: Data((meta + "<b>visible</b>").utf8))).get()
            #expect(rejected.fallbackReason != nil)
            #expect(RenderedPlainText.extract(from: MarkdownRenderer().render(rejected.text).body) == "visible")
        }
    }
    @Test func legitimateHeaderMetadataStillConverts() throws {
        let html = "<html><head><meta charset='utf-8'><title>Document</title></head><body><b>A</b>B</body></html>"
        let wrappedHTML = "<meta charset='utf-8'><html><head><title>Document</title></head><body><b>A</b>B</body></html>"
        let fragmentHead = "<head><title>Document</title></head><body><b>A</b>B</body>"
        let rtf = #"{\rtf1\ansi{\fonttbl{\f0 Arial;}}{\colortbl;\red0\green0\blue0;}{\*\generator Good;}\b A\b0 B}"#
        for payload in [MarkdownPaste.Payload(html: Data(html.utf8)), .init(html: Data(wrappedHTML.utf8)), .init(html: Data(fragmentHead.utf8)), .init(rtf: Data(rtf.utf8))] {
            let output = try MarkdownPaste.convert(.markdown, payload: payload).get()
            #expect(output.fallbackReason == nil)
            let body = MarkdownRenderer().render(output.text).body
            #expect(RenderedPlainText.extract(from: body) == "AB")
            #expect(body.contains("<strong>A</strong>"))
        }
    }
}

@MainActor
@Suite(.serialized)
struct MarkdownPasteLifecycleReviewRegressionTests {
    private actor Gate {
        var continuation: CheckedContinuation<Result<MarkdownPaste.Output, MarkdownPaste.Failure>, Never>?
        var ready: Bool { continuation != nil }
        func wait() async -> Result<MarkdownPaste.Output, MarkdownPaste.Failure> { await withCheckedContinuation { continuation = $0 } }
        func finish() { continuation?.resume(returning: MarkdownPaste.convert(.plainText, payload: .init(plainText: "LATE_INSERT"))); continuation = nil }
    }
    private func begin(_ editor: MarkdownSourceTextView) async throws -> (Gate, Task<Void, Never>) {
        let gate = Gate()
        editor.markdownPasteController.isFocusedSource = { _ in true }
        editor.markdownPasteController.capture = { _ in .success(.init(plainText: "LATE_INSERT")) }
        editor.markdownPasteController.convert = { _, _ in await gate.wait() }
        #expect(editor.markdownPasteController.perform(.plainText))
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await gate.ready), ContinuousClock.now < deadline { await Task.yield() }
        try #require(await gate.ready)
        var waiting = false
        let completion = Task { @MainActor in waiting = true; await editor.markdownPasteController.waitForPendingPaste() }
        while !waiting { await Task.yield() }
        return (gate, completion)
    }
    @Test func pN1SameTextResetInvalidatesWithoutRelyingOnTextChange() async throws {
        let undo = UndoManager(); undo.groupsByEvent = false
        let session = MarkdownEditorSession(undoManager: undo)
        let editor = try #require(session.loadTextView(text: "same") as? MarkdownSourceTextView)
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        let generation = session.pasteContextGeneration
        let (gate, completion) = try await begin(editor)
        #expect(session.resetText(to: "same"))
        #expect(session.pasteContextGeneration != generation)
        await gate.finish(); await completion.value
        #expect(editor.string == "same"); #expect(!undo.canUndo)
    }
    @Test(arguments: ["open-same-content", "rename", "first-save", "save-missing-file", "close", "new-document"])
    func pN1DocumentLifecycleCannotAdoptOldWork(_ change: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PasteLifecycle-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("a.md"), b = root.appendingPathComponent("b.md")
        let original = "same 中文🙂\n"
        try original.write(to: a, atomically: true, encoding: .utf8)
        if change == "open-same-content" { try original.write(to: b, atomically: true, encoding: .utf8) }
        let store = DocumentStore(saveLocationPicker: { _ in b }, autosaveDelay: 300)
        defer { _ = store.closeDocument(discardRecovery: true) }
        if change == "first-save" { store.text = original } else { store.open(a) }
        let editor = try #require(store.editorSession.loadTextView(text: store.text) as? MarkdownSourceTextView)
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        let (gate, completion) = try await begin(editor)
        var newStore: DocumentStore?
        switch change {
        case "open-same-content": store.open(b)
        case "rename": try FileManager.default.moveItem(at: a, to: b); store.refreshFileLocation()
        case "first-save": #expect(store.save())
        case "save-missing-file":
            try FileManager.default.removeItem(at: a)
            store.refreshFileLocation()
            #expect(store.backingFileMissing)
            #expect(store.save())
        case "new-document":
            #expect(store.closeDocument(discardRecovery: true))
            newStore = DocumentStore(autosaveDelay: 300)
            newStore?.text = original
        default: #expect(store.closeDocument(discardRecovery: true))
        }
        await gate.finish(); await completion.value
        #expect(editor.string == original); #expect(store.text == original)
        #expect(!store.undoManager.canUndo)
        if change == "close" || change == "new-document" { #expect(!editor.markdownPasteController.canPerform) }
        if let newStore { #expect(newStore.text == original); #expect(!newStore.undoManager.canUndo); _ = newStore.closeDocument(discardRecovery: true) }
        if FileManager.default.fileExists(atPath: b.path) { #expect(try Data(contentsOf: b) == Data(original.utf8)) }
    }
}
