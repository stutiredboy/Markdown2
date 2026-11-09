import AppKit
import SwiftUI
import WebKit
import XCTest
@testable import MD2App


@MainActor
final class InteractionTestWindow {
    let store = DocumentStore()
    let window: NSWindow
    let suite = "FindInteractionGUITests-\(UUID().uuidString)"
    let settings: AppSettings
    init() {
        _ = NSApplication.shared
        settings = AppSettings(defaults: UserDefaults(suiteName: suite)!)
        settings.newDocumentMode = .write
        settings.defaultMode = .write
        settings.showsOutlineByDefault = false
        window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 900, height: 650),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
    }
    func host<V: View>(_ root: V, width: CGFloat = 900, height: CGFloat = 650) {
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
    func descendants<T: NSView>(_ type: T.Type) -> [T] {
        func visit(_ view: NSView) -> [T] { ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap(visit) }
        guard let content = window.contentView else { return [] }
        return visit(content)
    }
    func press(_ key: L10nKey) throws {
        // Close is the rightmost button in a find-only surface; SwiftUI's
        // native subview order differs across OS versions.
        XCTAssertEqual(key, .closeFind)
        let buttons = descendants(NSButton.self)
        let button = try XCTUnwrap(buttons.max { $0.convert($0.bounds, to: nil).midX < $1.convert($1.bounds, to: nil).midX })
        button.performClick(nil)
        spin()
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
