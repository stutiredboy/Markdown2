import AppKit
import MD2Core
import SwiftUI
import WebKit
import XCTest
@testable import MD2App

/// Production preview hosts with their shared per-ContentView focus state.
/// The separate native permission-control oracle still exercises ContentView.
final class PreviewFocusGUITests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MD2_RUN_GUI_TESTS"] == "1", "Requires an exclusive native GUI session")
    }

    @MainActor func testResourceReplacementPreservesEditorAndNativeFieldFocus() throws {
        let h = PreviewFocusHarness()
        defer { h.close() }
        let initial = try h.ready()
        XCTAssertTrue(h.wait { h.window.firstResponder === initial })
        XCTAssertTrue(h.window.makeFirstResponder(h.editor))
        h.editor.setSelectedRange(NSRange(location: 1, length: 3))
        h.replaceResourceContext()
        let replacement = try h.ready(replacing: initial)
        XCTAssertFalse(replacement === initial)
        h.drain()
        XCTAssertTrue(h.window.firstResponder === h.editor)
        XCTAssertEqual(h.editor.selectedRange(), NSRange(location: 1, length: 3))

        XCTAssertTrue(h.window.makeFirstResponder(h.field))
        let fieldEditor = try XCTUnwrap(h.field.currentEditor())
        h.replaceResourceContext()
        _ = try h.ready(replacing: replacement)
        h.drain()
        XCTAssertTrue(h.window.firstResponder === fieldEditor)
    }

    @MainActor func testPreviewRestorationYieldsToAnInterveningNativeField() throws {
        let h = PreviewFocusHarness()
        defer { h.close() }
        let initial = try h.ready()
        XCTAssertTrue(h.window.makeFirstResponder(initial))
        h.replaceResourceContext()
        let restored = try h.ready(replacing: initial)
        XCTAssertTrue(h.wait { h.window.firstResponder === restored })

        // Capture legitimate old-preview ownership, then change the native owner
        // before the replacement host can consume the pending restoration.
        h.coordinator?.invalidateResourceContext(in: restored)
        XCTAssertTrue(h.window.makeFirstResponder(h.field))
        let fieldEditor = try XCTUnwrap(h.field.currentEditor())
        h.mountNewContext()
        _ = try h.ready(replacing: restored)
        h.drain()
        XCTAssertTrue(h.window.firstResponder === fieldEditor)
    }

    @MainActor func testRetiredQueuedRequestIsNotReplayedButANewExplicitRequestWorks() throws {
        let h = PreviewFocusHarness()
        defer { h.close() }
        let initial = try h.ready()
        XCTAssertTrue(h.window.makeFirstResponder(h.editor))
        let queuedToken = UUID()
        h.focusToken = queuedToken
        h.coordinator?.updateFocusRequest(queuedToken, state: h.focusState, in: initial)
        h.coordinator?.invalidateResourceContext(in: initial)
        h.mountNewContext()
        let replacement = try h.ready(replacing: initial)
        h.drain()
        XCTAssertTrue(h.window.firstResponder === h.editor)

        h.focusToken = UUID()
        h.update()
        XCTAssertTrue(h.wait { h.window.firstResponder === replacement }, "an explicit preview-focus command still takes effect")
    }
}

@MainActor private final class PreviewFocusHarness {
    let focusState = PreviewFocusState()
    var focusToken = UUID()
    private var resourceToken = UUID()
    private let hosting: NSHostingView<AnyView>
    let window: PreviewFocusWindow
    let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 250, height: 350))
    let field = NSTextField(frame: NSRect(x: 20, y: 360, width: 220, height: 28))
    var web: WKWebView? { findWeb(in: hosting) }
    var coordinator: MarkdownPreviewView.Coordinator? { web?.navigationDelegate as? MarkdownPreviewView.Coordinator }

    init() {
        _ = NSApplication.shared
        NSApp.finishLaunching()
        NSApp.activate(ignoringOtherApps: true)
        hosting = NSHostingView(rootView: AnyView(EmptyView()))
        window = PreviewFocusWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 850, height: 420),
                                    styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 850, height: 420))
        editor.string = "native editor selection"
        root.addSubview(editor); root.addSubview(field)
        hosting.frame = NSRect(x: 280, y: 0, width: 570, height: 420)
        root.addSubview(hosting); window.contentView = root
        window.makeKeyAndOrderFront(nil)
        update()
    }

    func update() {
        let rendered = MarkdownRenderer().render("# Focus\n\nA preview paragraph.", assetMode: .appScheme)
        let preview = MarkdownPreviewView(html: rendered.html, bodyHTML: rendered.body, baseURL: nil,
            remoteResourceContextToken: resourceToken,
            jumpHeadingID: .constant(nil), jumpFraction: .constant(nil), jumpAnchor: .constant(nil),
            findQuery: .constant(""), findNavigation: .constant(nil), focusToken: focusToken, focusState: focusState)
        hosting.rootView = AnyView(preview.id(resourceToken))
    }

    func replaceResourceContext() {
        if let web { coordinator?.invalidateResourceContext(in: web) }
        mountNewContext()
    }

    func mountNewContext() { resourceToken = UUID(); update() }

    func ready(replacing old: WKWebView? = nil) throws -> WKWebView {
        guard wait({ self.web != nil && self.web !== old && self.coordinator?.isLoaded == true }) else {
            throw NSError(domain: "PreviewFocusHarness", code: 1, userInfo: [NSLocalizedDescriptionKey: "The replacement preview did not become ready"])
        }
        return web!
    }

    func wait(_ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if condition() { return true }
            pump()
        }
        return condition()
    }

    func drain() {
        let deadline = Date().addingTimeInterval(0.25)
        while Date() < deadline { pump() }
    }

    private func pump() {
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        while let event = NSApp.nextEvent(matching: .any, until: Date(), inMode: .default, dequeue: true) { NSApp.sendEvent(event) }
    }

    func close() {
        if let web { coordinator?.invalidateResourceContext(in: web) }
        window.orderOut(nil); window.contentView = nil
    }

    private func findWeb(in view: NSView) -> WKWebView? {
        if let web = view as? WKWebView { return web }
        return view.subviews.lazy.compactMap(findWeb).first
    }
}

private final class PreviewFocusWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
