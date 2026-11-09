import AppKit
import SwiftUI
import WebKit
import XCTest
@testable import MD2App

final class ReadFormattingSelectionGUITests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MD2_RUN_GUI_TESTS"] == "1",
                          "Set MD2_RUN_GUI_TESTS=1 to run interaction GUI tests.")
    }

    @MainActor
    func testReadFormattingRevealsSourceWithoutGuessingRenderedSelections() throws {
        for renderedText in ["Beta\n\nBeta", "[Beta](https://example.com)", "$Beta$", "Beta first\n\nBeta second"] {
            let harness = InteractionTestWindow()
            defer { harness.close() }
            let original = renderedText + "\n\n" + String(repeating: "Filler paragraph.\n\n", count: 70) + "Alpha"
            harness.store.text = original
            harness.host(ContentView(document: harness.store, settings: harness.settings, onOpen: {}))
            let editor = try XCTUnwrap(harness.store.editorSession.textView)
            let target = (original as NSString).range(of: "Alpha")
            // A persisted search must not move the revealed formatting target
            // when the editor's new coordinator rebuilds its match index.
            harness.store.requestFind(.show)
            harness.spin()
            try harness.enterQuery("Beta")
            harness.spin(for: 0.4)
            try harness.press(.closeFind)
            editor.setSelectedRange(target)
            harness.store.requestMode(.read)
            harness.spin(until: { editor.window == nil && !harness.descendants(WKWebView.self).isEmpty })
            let web = try XCTUnwrap(harness.descendants(WKWebView.self).first)
            harness.spin(for: 1.2)
            let selection = try harness.js("""
                (() => {
                    const paragraphs = Array.from(document.querySelectorAll('p')).filter(p=>p.textContent.includes('Beta'));
                    const range = document.createRange();
                    range.setStartBefore(paragraphs[0]); range.setEndAfter(paragraphs[paragraphs.length-1]);
                    const selection = window.getSelection(); selection.removeAllRanges(); selection.addRange(range);
                    paragraphs[0].scrollIntoView(); return selection.toString();
                })()
                """, web) as? String
            XCTAssertTrue(selection?.contains("Beta") == true)
            harness.store.requestFormat(.bold)
            XCTAssertEqual(harness.store.text, original)
            harness.spin(until: { editor.window != nil })
            harness.spin(for: 0.5)
            XCTAssertEqual(harness.store.text, original)
            XCTAssertEqual(editor.selectedRange(), target)
            XCTAssertTrue(harness.store.showsFormattingTargetNotice)
            let layout = try XCTUnwrap(editor.layoutManager)
            let container = try XCTUnwrap(editor.textContainer)
            var rect = layout.boundingRect(forGlyphRange: layout.glyphRange(forCharacterRange: target, actualCharacterRange: nil), in: container)
            rect.origin.x += editor.textContainerOrigin.x
            rect.origin.y += editor.textContainerOrigin.y
            XCTAssertTrue(editor.visibleRect.intersects(rect), "the revealed source target must actually be visible")
            if renderedText == "Beta\n\nBeta" {
                harness.store.requestFind(.show)
                harness.spin()
                try harness.enterQuery("Filler")
                harness.spin(for: 0.4)
                XCTAssertFalse(harness.store.showsFormattingTargetNotice)
                XCTAssertEqual(editor.selectedRange().location, NSMaxRange((original as NSString).range(of: "Filler")),
                               "a deliberate new search must still reveal its match")
                try harness.press(.closeFind)
                editor.setSelectedRange(target)
            }
            XCTAssertTrue(harness.window.makeFirstResponder(editor))
            harness.store.requestFormat(.bold)
            harness.spin()
            XCTAssertEqual(harness.store.text, original.replacingOccurrences(of: "Alpha", with: "**Alpha**"))
        }
    }


}
