import AppKit
import SwiftUI
import XCTest
import MD2Core
@testable import MD2App

/// GUI-gated verification of the editor's line-number gutter, checking the
/// delivered pixels rather than the model: the gutter is drawn into the text
/// view's left inset, so whether it appears, where it aligns, and that it is
/// legible in both appearances can only be seen by rendering the view.
///
/// The guarded failures are silent — a gutter that stops drawing, numbers that
/// drift from their lines, or a gutter that never disappears — so these run on
/// demand rather than in the default suite:
/// `MD2_RUN_GUI_TESTS=1 swift test --filter EditorLineNumberGutterGUITests`.
///
/// Every assertion is scoped to the gutter strip (`x < 58pt`), never to a
/// whole-view pixel count: a blank view would satisfy a global count, and the
/// document text would dominate one.
final class EditorLineNumberGutterGUITests: XCTestCase {
    /// The text container inset the gutter lives in (see `MarkdownEditorView`).
    private let stripWidth: CGFloat = 58

    private let wrappedDocument = """
    # Heading

    A paragraph long enough that it must soft-wrap across several visual rows, which is the case the gutter has to handle by numbering the line once at its first row rather than once per wrapped row.

    Short line.
    """

    // MARK: - Drawn or not

    @MainActor
    func testGutterDrawsNumbersOnlyWhenEnabled() throws {
        try skipUnlessGUITestsEnabled()

        let off = try render(document: wrappedDocument, showsLineNumbers: false, height: 400)
        XCTAssertEqual(
            inkRows(inStripOf: off),
            [],
            "no gutter may be drawn when the line-number preference is off"
        )

        let on = try render(document: wrappedDocument, showsLineNumbers: true, height: 400)
        XCTAssertFalse(
            inkRows(inStripOf: on).isEmpty,
            "the gutter must be drawn when the line-number preference is on"
        )
    }

    // MARK: - One number per logical line

    @MainActor
    func testAWrappedParagraphIsNumberedOnce() throws {
        try skipUnlessGUITestsEnabled()

        // The paragraph above wraps across several rows but is a single source
        // line, so the gutter must show one ink band for it — not one per row.
        let bitmap = try render(document: wrappedDocument, showsLineNumbers: true, height: 500)
        let bands = inkBands(inStripOf: bitmap)

        // One band per *source* line — blank lines included, since they are
        // source lines too. The paragraph on line 3 occupies several visual rows;
        // a per-visual-row bug would add a band for each of its wrapped rows and
        // push the count above the document's line count.
        let sourceLineCount = wrappedDocument
            .split(separator: "\n", omittingEmptySubsequences: false)
            .count
        XCTAssertEqual(
            bands.count,
            sourceLineCount,
            "expected one number per source line; got \(bands.count) ink bands (\(bands)) for \(sourceLineCount) lines"
        )
    }

    // MARK: - Legibility

    @MainActor
    func testGutterIsLegibleInBothAppearances() throws {
        try skipUnlessGUITestsEnabled()

        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            let bitmap = try render(
                document: wrappedDocument,
                showsLineNumbers: true,
                height: 400,
                appearance: NSAppearance(named: appearanceName)
            )
            let strip = stripRows(in: bitmap)
            let background = bitmap.colorAt(x: 2, y: max(0, bitmap.pixelsHigh - 3))
            let contrasting = strip.flatMap { $0 }.filter { contrasts($0, background) }.count

            XCTAssertGreaterThan(
                contrasting,
                10,
                "the gutter is illegible under \(appearanceName.rawValue) (contrasting pixels: \(contrasting))"
            )
        }
    }

    // MARK: - Alignment

    @MainActor
    func testGutterKeepsDrawingAfterScrollingAndEditing() throws {
        try skipUnlessGUITestsEnabled()

        let context = try host(document: wrappedDocument, showsLineNumbers: true, height: 300)
        defer { context.close() }

        func bands() -> [ClosedRange<Int>] {
            guard let bitmap = context.rasterize() else { return [] }
            return inkBands(inStripOf: bitmap)
        }

        let atTop = bands()
        XCTAssertFalse(atTop.isEmpty, "no gutter was drawn at rest")
        // The first line's number sits just below the text container's top inset.
        XCTAssertLessThan(
            atTop.first?.lowerBound ?? .max,
            Int(context.textContainerInsetHeight) + 40,
            "the first number should sit at the top of the content"
        )
        XCTAssertGreaterThanOrEqual(
            atTop.first?.lowerBound ?? -1,
            Int(context.textContainerInsetHeight) - 4,
            "the first number must not be drawn above the content"
        )

        // Scrolled away from the top, numbers must still be drawn for the lines
        // now on screen.
        context.scroll(toY: 120)
        XCTAssertFalse(bands().isEmpty, "the gutter stopped drawing after scrolling")

        // An edit above the viewport renumbers every line below it; the gutter
        // must keep drawing (a stale or missing redraw here is the silent
        // regression this guards).
        context.replaceText(with: "# Added\n\n" + wrappedDocument)
        XCTAssertFalse(bands().isEmpty, "the gutter stopped drawing after an edit above the viewport")

        // And the whole point of drawing inside the inset: the document text must
        // not have moved. The text column starts at the container origin, so ink
        // right of it is text, and the gutter stays strictly left of it.
        XCTAssertEqual(
            context.textContainerOriginX,
            stripWidth,
            "the gutter must be drawn inside the existing text-container inset"
        )
    }

    // MARK: - Harness

    private func skipUnlessGUITestsEnabled() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["MD2_RUN_GUI_TESTS"] == "1",
            "Set MD2_RUN_GUI_TESTS=1 to run this AppKit-backed test."
        )
    }

    @MainActor
    private func render(
        document: String,
        showsLineNumbers: Bool,
        height: CGFloat,
        appearance: NSAppearance? = NSAppearance(named: .aqua)
    ) throws -> NSBitmapImageRep {
        let context = try host(
            document: document,
            showsLineNumbers: showsLineNumbers,
            height: height,
            appearance: appearance
        )
        defer { context.close() }
        guard let bitmap = context.rasterize() else {
            throw XCTSkip("the editor's text view did not render")
        }
        return bitmap
    }

    @MainActor
    private func host(
        document: String,
        showsLineNumbers: Bool,
        height: CGFloat,
        appearance: NSAppearance? = NSAppearance(named: .aqua)
    ) throws -> EditorHost {
        _ = NSApplication.shared

        let frame = NSRect(x: 0, y: 0, width: 620, height: height)
        let host = EditorHost(
            rootView: MarkdownEditorView(
                text: .constant(document),
                jumpLine: .constant(nil),
                jumpFraction: .constant(nil),
                jumpAnchor: .constant(nil),
                findQuery: .constant(""),
                findNavigation: .constant(nil),
                findReplacement: .constant(""),
                replaceCommand: .constant(nil),
                focusToken: UUID(),
                showsLineNumbers: showsLineNumbers
            )
        )
        try host.mount(frame: frame, appearance: appearance)
        return host
    }

    // MARK: - Pixel helpers

    private func inkRows(inStripOf bitmap: NSBitmapImageRep) -> [Int] {
        inkRows(inStripOf: bitmap, xRange: 0..<min(bitmap.pixelsWide, Int(stripWidth)))
    }

    /// Rows of the given x-band that contain ink, in raster (top-down) order.
    private func inkRows(inStripOf bitmap: NSBitmapImageRep, xRange: Range<Int>) -> [Int] {
        var rows: [Int] = []
        for y in 0..<bitmap.pixelsHigh {
            for x in xRange where isInk(bitmap.colorAt(x: x, y: y)) {
                rows.append(y)
                break
            }
        }
        return rows
    }

    private func stripRows(in bitmap: NSBitmapImageRep) -> [[NSColor?]] {
        (0..<bitmap.pixelsHigh).map { y in
            (0..<min(bitmap.pixelsWide, Int(stripWidth))).map { bitmap.colorAt(x: $0, y: y) }
        }
    }

    /// Contiguous runs of inked rows: one run per drawn number.
    private func inkBands(inStripOf bitmap: NSBitmapImageRep) -> [ClosedRange<Int>] {
        let rows = inkRows(inStripOf: bitmap)
        var bands: [ClosedRange<Int>] = []
        for row in rows {
            if let last = bands.last, row == last.upperBound + 1 {
                bands[bands.count - 1] = last.lowerBound...row
            } else {
                bands.append(row...row)
            }
        }
        return bands
    }

    /// Ink is any pixel clearly darker than white — gutter numbers use the
    /// secondary label colour, which is a mid grey in light appearance.
    private func isInk(_ color: NSColor?) -> Bool {
        guard let c = color?.usingColorSpace(.deviceRGB) else { return false }
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
        c.getRed(&r, green: &g, blue: &b, alpha: nil)
        return (r + g + b) / 3 < 0.86
    }

    private func contrasts(_ color: NSColor?, _ background: NSColor?) -> Bool {
        guard let a = color?.usingColorSpace(.deviceRGB),
              let b = background?.usingColorSpace(.deviceRGB) else { return false }
        var ar: CGFloat = 0, ag: CGFloat = 0, ab: CGFloat = 0
        var br: CGFloat = 0, bg: CGFloat = 0, bb: CGFloat = 0
        a.getRed(&ar, green: &ag, blue: &ab, alpha: nil)
        b.getRed(&br, green: &bg, blue: &bb, alpha: nil)
        let delta = abs((ar + ag + ab) - (br + bg + bb)) / 3
        return delta > 0.15
    }
}

/// Hosts a `MarkdownEditorView` in a real window and exposes the pieces the
/// pixel assertions need: the rendered bitmap, the text container's origin, and
/// a way to scroll or replace the document.
@MainActor
private final class EditorHost: NSObject {
    private let hostingView: NSHostingView<MarkdownEditorView>
    private var window: NSWindow?
    private var scrollView: NSScrollView?

    init(rootView: MarkdownEditorView) {
        hostingView = NSHostingView(rootView: rootView)
        super.init()
    }

    func mount(frame: NSRect, appearance: NSAppearance?) throws {
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = appearance
        hostingView.frame = frame
        window.contentView = hostingView
        window.setFrameOrigin(NSPoint(x: -30_000, y: -30_000))
        window.orderFrontRegardless()
        self.window = window

        // Let SwiftUI build the representable and TextKit lay the text out.
        pumpRunLoop()
        scrollView = Self.firstScrollView(in: hostingView)
        guard scrollView != nil else {
            throw XCTSkip("the editor's scroll view did not materialise")
        }
    }

    func close() {
        window?.orderOut(nil)
        window = nil
    }

    var textView: NSTextView? {
        scrollView?.documentView as? NSTextView
    }

    var textContainerOriginX: CGFloat {
        textView?.textContainerOrigin.x ?? 0
    }

    var textContainerInsetHeight: CGFloat {
        textView?.textContainerInset.height ?? 0
    }

    func rasterize() -> NSBitmapImageRep? {
        guard let textView else { return nil }
        let rect = textView.visibleRect
        let width = Int(rect.width.rounded()), height = Int(rect.height.rounded())
        guard width > 0, height > 0,
              let rep = NSBitmapImageRep(
                  bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                  colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
              ) else { return nil }
        // Draw the view straight into the bitmap rather than through the window
        // server: this window is parked off-screen, and `cacheDisplay` leaves the
        // bitmap empty for a view that never composites.
        NSGraphicsContext.saveGraphicsState()
        if let context = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.current = context
            // The text view is flipped, so flip the bitmap to match: the app's own
            // display pass hands the view a flipped context, and drawing into an
            // unflipped one would mirror everything vertically.
            context.cgContext.translateBy(x: 0, y: CGFloat(height))
            context.cgContext.scaleBy(x: 1, y: -1)
            context.cgContext.setFillColor(NSColor.textBackgroundColor.cgColor)
            context.cgContext.fill(CGRect(x: 0, y: 0, width: width, height: height))
            textView.draw(rect)
            context.flushGraphics()
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    func scroll(toY y: CGFloat) {
        guard let scrollView else { return }
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        pumpRunLoop()
    }

    func replaceText(with text: String) {
        guard let textView, let storage = textView.textStorage else { return }
        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: text)
        // The edit path restyles and invalidates the gutter; trigger the same
        // delegate callbacks a user edit would.
        textView.didChangeText()
        pumpRunLoop()
    }

    private func pumpRunLoop() {
        let deadline = Date().addingTimeInterval(0.35)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
    }

    private static func firstScrollView(in view: NSView) -> NSScrollView? {
        if let scrollView = view as? NSScrollView { return scrollView }
        for subview in view.subviews {
            if let found = firstScrollView(in: subview) { return found }
        }
        return nil
    }
}
