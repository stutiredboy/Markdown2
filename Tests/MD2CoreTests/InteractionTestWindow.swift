import AppKit
import SwiftUI
import WebKit
import XCTest
@testable import MD2App


/// Observe the real WebKit highlight registry. A match spanning multiple
/// inline text nodes contributes one range per painted fragment.
enum PreviewFindRanges {
    static let all = "Array.from(CSS.highlights.get('md2-find') ?? [])"
    static let count = "(CSS.highlights.get('md2-find')?.size ?? 0)"
    static let currentCount = "(CSS.highlights.get('md2-find-current')?.size ?? 0)"
    static let firstText = "\(all)[0]?.toString()"
    static let currentIndex = "\(all).findIndex(range => CSS.highlights.get('md2-find-current')?.has(range))"
}

@MainActor
final class InteractionTestWindow {
    let store: DocumentStore
    let window: NSWindow
    let suite = "FindInteractionGUITests-\(UUID().uuidString)"
    let settings: AppSettings
    init(store: DocumentStore = DocumentStore(), window: NSWindow? = nil) {
        _ = NSApplication.shared
        self.store = store
        settings = AppSettings(defaults: UserDefaults(suiteName: suite)!)
        settings.newDocumentMode = .write
        settings.defaultMode = .write
        settings.showsOutlineByDefault = false
        self.window = window ?? NSWindow(contentRect: NSRect(x: 100, y: 100, width: 900, height: 650),
                                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        self.window.isReleasedWhenClosed = false
        self.window.animationBehavior = .none
    }
    func host<V: View>(_ root: V, width: CGFloat = 900, height: CGFloat = 650) {
        window.title = store.displayTitle
        window.representedURL = store.fileURL
        window.setContentSize(NSSize(width: width, height: height))
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        let host = NSHostingView(rootView: root)
        host.frame = container.bounds
        host.autoresizingMask = [.width, .height]
        container.addSubview(host)
        window.contentView = container
        window.makeKeyAndOrderFront(nil)
        spin(for: 0.4)
    }
    var screenBounds: NSRect { window.convertToScreen(window.contentView!.bounds) }
    var queryField: NSTextField? { descendants(NSTextField.self).first { $0.placeholderString == settings.text(.findPlaceholder) } }
    func descendants<T: NSView>(_ type: T.Type, in root: NSView? = nil) -> [T] {
        func visit(_ view: NSView) -> [T] { ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap(visit) }
        guard let content = root ?? window.contentView else { return [] }
        return visit(content)
    }
    func press(_ key: L10nKey) throws {
        XCTAssertEqual(key, .closeFind)
        let query = try XCTUnwrap(queryField)
        var responder: NSResponder? = query
        while let current = responder, !(current is NativeFindPaneOwner) {
            responder = current.nextResponder
        }
        let owner = try XCTUnwrap(responder as? NSViewController, "the native query must have a Find bar owner")
        let queryCenterY = query.convert(query.bounds, to: nil).midY
        let queryRowButtons = descendants(NSButton.self, in: owner.view).filter {
            let frame = $0.convert($0.bounds, to: nil)
            return frame.minY <= queryCenterY && queryCenterY <= frame.maxY
        }
        // Close follows Previous and Next in the query row. Replace All may
        // extend farther right on the replacement row at narrow widths.
        XCTAssertEqual(queryRowButtons.count, 3)
        let button = try XCTUnwrap(queryRowButtons.max {
            $0.convert($0.bounds, to: nil).midX < $1.convert($1.bounds, to: nil).midX
        })
        button.performClick(nil)
        spin(until: { queryField == nil })
        XCTAssertNil(queryField, "closing Find must remove its native query field")
    }
    func findKey(previous: Bool = false) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero,
                         modifierFlags: previous ? [.command, .shift] : .command,
                         timestamp: 0, windowNumber: window.windowNumber, context: nil,
                         characters: "g", charactersIgnoringModifiers: "g", isARepeat: false, keyCode: 5)!
    }
    func enterQuery(_ value: String) throws {
        let field = try XCTUnwrap(queryField)
        XCTAssertTrue(window.makeFirstResponder(field))
        let editor = try XCTUnwrap(field.currentEditor())
        editor.selectAll(nil)
        editor.insertText(value)
    }
    func js(_ script: String, _ web: WKWebView) throws -> Any? {
        var done = false
        var result: Any?
        var error: Error?
        web.evaluateJavaScript(script) { value, failure in result = value; error = failure; done = true }
        spin(until: { done })
        XCTAssertTrue(done)
        if let error { throw error }
        return result
    }
    /// Observe the page the user will act on; a WKWebView in the hierarchy can
    /// still contain about:blank or an outgoing render. Never run find ourselves
    /// to satisfy the condition: the product must restore its own query.
    func waitForPage(_ predicate: String, in web: WKWebView, context: String,
                     requireLoaded: Bool = true, file: StaticString = #filePath, line: UInt = #line) throws {
        var satisfied = false
        var lastError: Error?
        spin(until: {
            do {
                let matches = try js(predicate, web) as? Bool == true
                let loaded = (web.navigationDelegate as? MarkdownPreviewView.Coordinator)?.isLoaded == true
                satisfied = matches && (!requireLoaded || (loaded && !web.isLoading))
            } catch { lastError = error }
            return satisfied
        })
        guard !satisfied else { return }
        let page = try? js("""
            JSON.stringify({url:location.href,ready:document.readyState,
              text:document.querySelector('main')?.textContent.slice(0,600),
              paragraphs:document.querySelectorAll('p').length,
              findAPI:typeof window.__md2Find,matches:\(PreviewFindRanges.count),
              index:\(PreviewFindRanges.currentIndex)})
            """, web)
        let coordinator = web.navigationDelegate as? MarkdownPreviewView.Coordinator
        _ = try XCTUnwrap(satisfied ? true : nil,
            "\(context): isLoading=\(web.isLoading), loaded=\(String(describing: coordinator?.isLoaded)), query=\(String(describing: coordinator?.lastFindQuery)), page=\(String(describing: page)), error=\(String(describing: lastError))",
            file: file, line: line)
    }

    func clickPreviewScrollTrack(in web: WKWebView) throws {
        // Wake the transient system scrollbar on Macs configured to hide it.
        // The track click must then advance past the current reading position.
        _ = try js("scrollBy(0, -8); true", web)
        let location = web.convert(NSPoint(x: web.bounds.maxX - 5, y: web.bounds.height * 0.85), to: nil)
        for kind: NSEvent.EventType in [.mouseMoved, .leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: kind, location: location, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: kind == .mouseMoved ? 0 : 1, pressure: kind == .leftMouseDown ? 1 : 0))
            switch kind {
            case .mouseMoved: web.mouseMoved(with: event)
            case .leftMouseDown: web.mouseDown(with: event)
            default: web.mouseUp(with: event)
            }
        }
    }

    /// WebKit receives the native events at the CSS viewport coordinates.
    func drag(from start: NSPoint, to end: NSPoint, in web: WKWebView) throws {
        try moveMouse(to: start, in: web)
        web.mouseDown(with: try previewMouseEvent(.leftMouseDown, at: start, in: web))
        for step in 1...6 {
            let fraction = CGFloat(step) / 6
            let point = NSPoint(x: start.x + (end.x - start.x) * fraction,
                                y: start.y + (end.y - start.y) * fraction)
            try dragMouse(to: point, in: web)
            spin(for: 0.025)
        }
        web.mouseUp(with: try previewMouseEvent(.leftMouseUp, at: end, in: web))
    }

    func moveMouse(to point: NSPoint, in web: WKWebView) throws {
        web.mouseMoved(with: try previewMouseEvent(.mouseMoved, at: point, in: web))
    }

    func dragMouse(to point: NSPoint, in web: WKWebView) throws {
        web.mouseDragged(with: try previewMouseEvent(.leftMouseDragged, at: point, in: web))
    }

    func click(at point: NSPoint, count: Int = 1, modifiers: NSEvent.ModifierFlags = [], in web: WKWebView) throws {
        for click in 1...count {
            web.mouseDown(with: try previewMouseEvent(.leftMouseDown, at: point, in: web, count: click, modifiers: modifiers))
            web.mouseUp(with: try previewMouseEvent(.leftMouseUp, at: point, in: web, count: click, modifiers: modifiers))
        }
    }

    private func previewMouseEvent(_ type: NSEvent.EventType, at point: NSPoint, in web: WKWebView,
                                   count: Int = 1, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        let y = web.isFlipped ? point.y : web.bounds.height - point.y
        let location = web.convert(NSPoint(x: point.x, y: y), to: nil)
        return try XCTUnwrap(NSEvent.mouseEvent(with: type, location: location, modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: type == .mouseMoved ? 0 : count,
            pressure: type == .leftMouseDown || type == .leftMouseDragged ? 1 : 0))
    }

    func targetRect(_ range: NSRange, in editor: NSTextView) -> NSRect {
        guard let layout = editor.layoutManager, let container = editor.textContainer else { return .zero }
        var rect = layout.boundingRect(forGlyphRange: layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil), in: container)
        rect.origin.x += editor.textContainerOrigin.x
        rect.origin.y += editor.textContainerOrigin.y
        return rect
    }

    func waitForTarget(_ range: NSRange, in editor: NSTextView, context: String,
                       file: StaticString = #filePath, line: UInt = #line) throws {
        var visible = false
        spin(until: {
            visible = editor.window != nil && !store.editorSession.revealSelectionOnNextHost
                && editor.visibleRect.intersects(targetRect(range, in: editor))
            return visible
        })
        _ = try XCTUnwrap(visible ? true : nil,
            "\(context): pending=\(store.editorSession.revealSelectionOnNextHost), window=\(editor.window != nil), clip=\(String(describing: editor.enclosingScrollView?.contentView.bounds)), frame=\(editor.frame), visible=\(editor.visibleRect), target=\(targetRect(range, in: editor)), selection=\(editor.selectedRange())",
            file: file, line: line)
    }
    func capture(_ name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["MD2_INTERACTION_EVIDENCE_DIR"],
              let view = window.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".png"))
    }
    func close() {
        window.orderOut(nil)
        window.contentView = nil
        spin()
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }
    func spin(for duration: TimeInterval = 0.2) {
        let deadline = Date().addingTimeInterval(duration)
        while Date() < deadline { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
    }
    func spin(until predicate: () -> Bool, timeout: TimeInterval = 5) {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate(), Date() < deadline { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
    }
}
