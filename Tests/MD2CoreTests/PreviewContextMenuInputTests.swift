import AppKit
import Testing
@testable import MD2App

@Suite @MainActor struct PreviewContextMenuInputTests {
    private let page = URL(string: "md2-doc://document/input-test/index.html")!
    private let point = NSPoint(x: 79, y: 78)

    @Test func originalRightClickMatchesDOMPointAndIsConsumedOnce() throws {
        var input = PreviewContextMenuInput()
        let event = try mouse(.rightMouseDown)
        input.record(event, point: point, page: page, windowNumber: 42)
        let pendingcaptured = input.take(for: page)
        let captured = try #require(pendingcaptured)
        #expect(captured.point == point)
        #expect(input.matches(captured, page: page, point: point, windowNumber: 42))
        // The real trace's willOpenMenu callback supplied (0,600). The actual
        // captured input must still match the DOM point and reject that point.
        #expect(!input.matches(captured, page: page, point: NSPoint(x: 0, y: 600), windowNumber: 42))
        let emptyCapture1 = input.take(for: page)
        #expect(emptyCapture1 == nil)
    }

    @Test func controlLeftMatchesButOrdinaryClicksReplaceOldInput() throws {
        var input = PreviewContextMenuInput()
        input.record(try mouse(.leftMouseDown, modifiers: .control), point: point, page: page, windowNumber: 42)
        let pendingcaptured = input.take(for: page)
        let captured = try #require(pendingcaptured)
        #expect(input.matches(captured, page: page, point: point, windowNumber: 42))
        input.record(try mouse(.leftMouseDown), point: point, page: page, windowNumber: 42)
        let emptyCapture2 = input.take(for: page)
        #expect(emptyCapture2 == nil)
        #expect(!input.matches(captured, page: page, point: point, windowNumber: 42))
    }

    @Test func cancelledReplacedOrWrongPageInputsCannotBind() throws {
        var input = PreviewContextMenuInput()
        input.record(try mouse(.rightMouseDown), point: point, page: page, windowNumber: 42)
        let pendingfirst = input.take(for: page)
        let first = try #require(pendingfirst)
        input.record(try mouse(.rightMouseDown), point: point, page: page, windowNumber: 42)
        #expect(!input.matches(first, page: page, point: point, windowNumber: 42))
        let pendingnext = input.take(for: page)
        let next = try #require(pendingnext)
        input.invalidate()
        #expect(!input.matches(next, page: page, point: point, windowNumber: 42))
        let emptyCapture3 = input.take(for: page)
        #expect(emptyCapture3 == nil)
        input.record(try mouse(.rightMouseDown), point: point, page: page, windowNumber: 42)
        let emptyCapture4 = input.take(for: URL(string: "md2-doc://document/replaced/index.html"))
        #expect(emptyCapture4 == nil)
        let emptyCapture5 = input.take(for: page)
        #expect(emptyCapture5 == nil)
    }

    @Test func missingNativeInputWrongWindowAndSyntheticMenuCallbackFailClosed() throws {
        var input = PreviewContextMenuInput()
        let emptyCapture6 = input.take(for: page)
        #expect(emptyCapture6 == nil)
        input.record(try mouse(.rightMouseDown), point: point, page: page, windowNumber: 99)
        let emptyCapture7 = input.take(for: page)
        #expect(emptyCapture7 == nil)
        input.record(try mouse(.rightMouseDown), point: point, page: nil, windowNumber: 42)
        let emptyCapture8 = input.take(for: page)
        #expect(emptyCapture8 == nil)
        let synthetic = try #require(NSEvent.otherEvent(with: .appKitDefined, location: .zero,
            modifierFlags: [], timestamp: 1, windowNumber: 42, context: nil, subtype: 0, data1: 0, data2: 0))
        input.record(synthetic, point: point, page: page, windowNumber: 42)
        let emptyCapture9 = input.take(for: page)
        #expect(emptyCapture9 == nil)
        input.record(try mouse(.rightMouseDown), point: point, page: page, windowNumber: 42)
        let pendingcaptured = input.take(for: page)
        let captured = try #require(pendingcaptured)
        #expect(!input.matches(captured, page: page, point: point, windowNumber: 99))
        #expect(!input.matches(captured, page: page, point: NSPoint(x: CGFloat.nan, y: 78), windowNumber: 42))
    }

    private func mouse(_ type: NSEvent.EventType, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: modifiers,
            timestamp: 1, windowNumber: 42, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
    }
}
