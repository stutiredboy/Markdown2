import AppKit
import SwiftUI
import WebKit
import XCTest
@testable import MD2App

/// GUI-gated guards for the document toolbar at narrow widths. Plain `swift test`
/// skips these (`MD2_RUN_GUI_TESTS` unset) and CI's `gui-tests` job runs them; run
/// locally with `MD2_RUN_GUI_TESTS=1 swift test --filter DocumentToolbarGUITests`.
///
/// The guarded failure is silent: `NSToolbar` moves what does not fit into its
/// overflow menu, trailing end first, and nothing reports it. Each test hosts the
/// real `ContentView`, so the toolbar is the one SwiftUI bridges onto a document
/// window, and reads `visibleItems` from it. They check which controls are
/// present rather than exact widths, because CI runs a different macOS and
/// toolbar metrics change between releases.
final class DocumentToolbarGUITests: XCTestCase {
    /// Starts at the narrowest width a window can take, so the first layout has
    /// to collapse, and ends there again, so the labels also collapse on a live
    /// resize. Side by Side stops at its own, wider minimum.
    private static let widthSweep: [CGFloat] = [780, 800, 900, 980, 1100, 1300, 780]

    // MARK: - The mode control stays in the toolbar

    @MainActor
    func testModeControlStaysVisibleAtEveryWidth() throws {
        try skipUnlessGUITestsEnabled()
        for language in [AppLanguage.english, .zhHans] {
            for document in [Self.frontMatterDocument, Self.plainDocument] {
                for mode in EditorMode.allCases {
                    let harness = try ToolbarWindowHarness(language: language, mode: mode, text: document)
                    defer { harness.close() }
                    let toolbarHeight = harness.toolbarHeight

                    for width in Self.widthSweep {
                        harness.resize(toWidth: width)
                        assertModeControlVisible(in: harness)
                        XCTAssertEqual(
                            harness.toolbarHeight,
                            toolbarHeight,
                            "labels collapsing must not move the content panes (\(harness.description))"
                        )
                    }
                }
            }
        }
    }

    @MainActor
    func testModeControlStaysVisibleWithALongFileName() throws {
        try skipUnlessGUITestsEnabled()
        let name = String(repeating: "a long document name ", count: 8) + ".md"
        let url = try Self.makeTemporaryDocument(named: name)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        for language in [AppLanguage.english, .zhHans] {
            let harness = try ToolbarWindowHarness(language: language, mode: .split, fileURL: url)
            defer { harness.close() }
            for width in Self.widthSweep {
                harness.resize(toWidth: width)
                assertModeControlVisible(in: harness)
            }
        }
    }

    @MainActor
    func testModeControlStaysVisibleWithTheOutlineShown() throws {
        try skipUnlessGUITestsEnabled()
        for mode in EditorMode.allCases {
            let harness = try ToolbarWindowHarness(
                language: .english,
                mode: mode,
                text: Self.frontMatterDocument,
                showsOutline: true
            )
            defer { harness.close() }
            for width in Self.widthSweep {
                harness.resize(toWidth: width)
                assertModeControlVisible(in: harness)
            }
        }
    }

    // MARK: - What the labels say

    @MainActor
    func testDefaultWidthLabelsPrimaryActions() throws {
        try skipUnlessGUITestsEnabled()
        for language in [AppLanguage.english, .zhHans] {
            let harness = try ToolbarWindowHarness(language: language, mode: .split, text: Self.frontMatterDocument)
            defer { harness.close() }
            harness.resize(toWidth: DocumentLayoutMetrics.defaultWindowWidth)
            let settings = harness.settings

            for action in [settings.text(.showOutline), settings.text(.open), settings.text(.save)] {
                XCTAssertTrue(
                    harness.spin(until: { harness.isVisible(action) }, timeout: 3),
                    "\(action) must stay in the toolbar at the default width (\(harness.description))"
                )
            }
            assertModeControlVisible(in: harness)
            let picker = try XCTUnwrap(harness.picker)
            XCTAssertEqual(
                (0..<picker.segmentCount).map { picker.label(forSegment: $0) },
                harness.modeNames,
                "the mode control must show its text at the default width"
            )
        }
    }

    @MainActor
    func testCollapsedControlsKeepLocalizedNamesAndHelp() throws {
        try skipUnlessGUITestsEnabled()
        for language in [AppLanguage.english, .zhHans] {
            let harness = try ToolbarWindowHarness(language: language, mode: .split, text: Self.frontMatterDocument)
            defer { harness.close() }
            harness.resize(toWidth: 800)
            assertModeControlVisible(in: harness)
            let settings = harness.settings

            let picker = try XCTUnwrap(harness.picker)
            XCTAssertTrue(
                harness.spin(until: { picker.label(forSegment: 0) ?? "" == "" }, timeout: 3),
                "the mode control should have collapsed to icons (\(harness.description))"
            )
            XCTAssertNotNil(picker.image(forSegment: 0))
            // An icon segment is announced by its image. Left alone, that is the
            // symbol's own description, in the system language.
            XCTAssertEqual(ToolbarWindowHarness.radioButtonLabels(in: picker), harness.modeNames)

            // Where `.help` can be read back depends on the macOS release. Open
            // never collapses, so it shows whether this one allows it at all.
            let open = try XCTUnwrap(harness.item(labelled: settings.text(.open)))
            guard harness.helpTexts(of: open).contains(settings.text(.open)) else {
                print("Toolbar help cannot be read back on this macOS, so only the names were checked.")
                continue
            }

            let helpByItem = [
                settings.text(.mode): settings.text(.writeReadOrSplit),
                settings.text(.lineNumbers): settings.text(.lineNumbersHelp),
                settings.text(.showMetadata): settings.text(.showMetadata)
            ]
            for (label, help) in helpByItem {
                let item = try XCTUnwrap(harness.item(labelled: label), "\(label) left the toolbar")
                let found = harness.helpTexts(of: item)
                XCTAssertTrue(found.contains(help), "\(label) lost its help text when it collapsed, found \(found)")
            }
        }
    }

    // MARK: - Mode switching

    @MainActor
    func testCompactPickerSwitchesModes() throws {
        try skipUnlessGUITestsEnabled()
        let harness = try ToolbarWindowHarness(language: .english, mode: .write, text: Self.frontMatterDocument)
        defer { harness.close() }
        harness.resize(toWidth: 850)
        assertModeControlVisible(in: harness)
        let metadata = harness.settings.text(.showMetadata)
        XCTAssertFalse(harness.isVisible(metadata), "Write mode has no metadata button")

        try harness.clickSegment(1)
        XCTAssertTrue(
            harness.spin(until: { harness.showsEditor && harness.showsPreview }),
            "the Side by Side segment never showed both panes"
        )
        XCTAssertTrue(harness.spin(until: { harness.isVisible(metadata) }))

        try harness.clickSegment(2)
        XCTAssertTrue(
            harness.spin(until: { !harness.showsEditor && harness.showsPreview }),
            "the Read segment never left the editor"
        )

        // The Mode menu and the shortcuts go through the store; the picker follows.
        harness.store.requestMode(.write)
        XCTAssertTrue(harness.spin(until: { harness.picker?.selectedSegment == 0 }))
        XCTAssertTrue(harness.spin(until: { harness.showsEditor && !harness.showsPreview }))
    }

    /// The metadata button appears with the switch out of Write mode. The picker
    /// must not move when it does: the pointer that made the switch is still on
    /// the picker, and a second click would land on a different segment.
    @MainActor
    func testSwitchingModeDoesNotMoveThePicker() throws {
        try skipUnlessGUITestsEnabled()
        for width: CGFloat in [850, 1000, 1300] {
            let harness = try ToolbarWindowHarness(language: .english, mode: .write, text: Self.frontMatterDocument)
            defer { harness.close() }
            harness.resize(toWidth: width)
            assertModeControlVisible(in: harness)
            let origin = try XCTUnwrap(harness.pickerX)

            for mode in [EditorMode.split, .read, .write] {
                harness.store.requestMode(mode)
                XCTAssertTrue(harness.spin(until: { harness.picker?.selectedSegment == Self.segment(of: mode) }))
                harness.spin(for: 0.4)
                XCTAssertEqual(harness.pickerX, origin, "the picker moved in \(mode) at \(width) pt")
            }
        }
    }

    // MARK: - Helpers

    @MainActor
    private func assertModeControlVisible(
        in harness: ToolbarWindowHarness,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let mode = harness.settings.text(.mode)
        XCTAssertTrue(
            harness.spin(until: { harness.isVisible(mode) }, timeout: 3),
            "the mode control fell out of the toolbar (\(harness.description))",
            file: file,
            line: line
        )
    }

    private static func segment(of mode: EditorMode) -> Int {
        EditorMode.allCases.firstIndex(of: mode) ?? -1
    }

    private static let frontMatterDocument = "---\ntitle: Toolbar\nauthor: Someone\n---\n\n# Heading\n"
    private static let plainDocument = "# Heading\n"

    private static func makeTemporaryDocument(named name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("md2-toolbar-gui-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try frontMatterDocument.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func skipUnlessGUITestsEnabled() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["MD2_RUN_GUI_TESTS"] == "1",
            "Set MD2_RUN_GUI_TESTS=1 to run this toolbar GUI test."
        )
    }
}

/// The real `ContentView` in a window with a document window's style, kept
/// off-screen and without ordering animations like the other window-hosted suites.
@MainActor
private final class ToolbarWindowHarness {
    let store = DocumentStore()
    let settings: AppSettings
    let window: NSWindow
    private let defaultsSuiteName: String

    init(
        language: AppLanguage,
        mode: EditorMode,
        text: String? = nil,
        fileURL: URL? = nil,
        showsOutline: Bool = false
    ) throws {
        _ = NSApplication.shared
        defaultsSuiteName = "DocumentToolbarGUITests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: defaultsSuiteName) else {
            throw XCTSkip("could not create a private defaults suite")
        }
        settings = AppSettings(defaults: defaults)
        settings.language = language
        settings.defaultMode = mode
        settings.newDocumentMode = mode
        settings.showsOutlineByDefault = showsOutline
        if let fileURL { store.open(fileURL) }
        if let text { store.text = text }

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.contentView = NSHostingView(
            rootView: ContentView(document: store, settings: settings, onOpen: {})
        )
        window.setFrameOrigin(NSPoint(x: -30_000, y: -30_000))
        window.orderFrontRegardless()
        spin(for: 1.2)
    }

    func close() {
        autoreleasepool {
            window.orderOut(nil)
            window.contentView = nil
        }
        spin(for: 0.2)
        UserDefaults(suiteName: defaultsSuiteName)?.removePersistentDomain(forName: defaultsSuiteName)
    }

    func resize(toWidth width: CGFloat) {
        var frame = window.frame
        frame.size.width = width
        window.setFrame(frame, display: true)
        spin(for: 0.5)
    }

    // MARK: Toolbar

    var modeNames: [String] {
        [settings.text(.write), settings.text(.sideBySide), settings.text(.read)]
    }

    func item(labelled label: String) -> NSToolbarItem? {
        window.toolbar?.items.first { $0.label == label }
    }

    func isVisible(_ label: String) -> Bool {
        window.toolbar?.visibleItems?.contains { $0.label == label } == true
    }

    var picker: NSSegmentedControl? {
        item(labelled: settings.text(.mode))?.view.flatMap { Self.firstDescendant(of: $0, as: NSSegmentedControl.self) }
    }

    var pickerX: CGFloat? {
        picker.map { $0.convert(NSPoint.zero, to: nil).x }
    }

    /// The window's height above its content, which is the toolbar's.
    var toolbarHeight: CGFloat {
        window.frame.height - window.contentLayoutRect.height
    }

    /// Everywhere `.help` can be read back from: the item, its views, and their
    /// accessibility elements.
    func helpTexts(of item: NSToolbarItem) -> Set<String> {
        var texts = Set([item.toolTip].compactMap { $0 })
        if let view = item.view {
            texts.formUnion(Self.toolTips(in: view))
            texts.formUnion(Self.accessibilityHelp(in: view))
        }
        return texts
    }

    private static func toolTips(in view: NSView) -> [String] {
        [view.toolTip].compactMap { $0 } + view.subviews.flatMap { toolTips(in: $0) }
    }

    private static func accessibilityHelp(in element: Any) -> [String] {
        let object = element as AnyObject
        let help = object.accessibilityHelp?() ?? nil
        let children = (object.accessibilityChildren?() ?? []) ?? []
        return [help].compactMap { $0 } + children.flatMap { accessibilityHelp(in: $0) }
    }

    func clickSegment(_ index: Int) throws {
        let picker = try XCTUnwrap(self.picker, "the mode control is not in the toolbar")
        picker.selectedSegment = index
        picker.sendAction(picker.action, to: picker.target)
    }

    var description: String {
        let visible = window.toolbar?.visibleItems?.map(\.label) ?? []
        return "\(settings.language) at \(window.frame.width) pt, showing \(visible)"
    }

    static func radioButtonLabels(in element: Any) -> [String] {
        let object = element as AnyObject
        if object.accessibilityRole?() == .radioButton {
            let label = object.accessibilityLabel?() ?? nil
            return [label ?? ""]
        }
        return ((object.accessibilityChildren?() ?? []) ?? []).flatMap { radioButtonLabels(in: $0) }
    }

    // MARK: Surfaces

    var showsEditor: Bool {
        window.contentView.flatMap { Self.firstDescendant(of: $0, as: MarkdownSourceTextView.self) } != nil
    }

    var showsPreview: Bool {
        window.contentView.flatMap { Self.firstDescendant(of: $0, as: WKWebView.self) } != nil
    }

    private static func firstDescendant<View: NSView>(of root: NSView, as type: View.Type) -> View? {
        if let match = root as? View { return match }
        for subview in root.subviews {
            if let match = firstDescendant(of: subview, as: type) { return match }
        }
        return nil
    }

    // MARK: Run loop

    func spin(for seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    @discardableResult
    func spin(until condition: () -> Bool, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            spin(for: 0.02)
        }
        return condition()
    }
}
