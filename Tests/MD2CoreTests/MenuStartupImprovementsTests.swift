import Foundation
import Testing
@testable import MD2App
@testable import MD2Core

@MainActor
struct MenuStartupImprovementsTests {
    private func makeSettings() -> AppSettings {
        let defaults = UserDefaults(suiteName: "MenuStartupTests-\(UUID().uuidString)")!
        return AppSettings(defaults: defaults)
    }

    // MARK: - Language-code resolver (task 6.1)

    @Test func appleLanguagesOverrideResolvesFromStoredLanguage() {
        #expect(AppLanguage.english.appleLanguagesOverride == ["en"])
        #expect(AppLanguage.zhHans.appleLanguagesOverride == ["zh-Hans"])
        // `.system` resolves to nil (no override) so the process follows the
        // system locale — it must NOT resolve to a concrete code.
        #expect(AppLanguage.system.appleLanguagesOverride == nil)
    }

    @Test func applyStoredLanguageOverrideWritesAndRemovesAppleLanguages() {
        let suiteName = "MenuStartupTests-applelang-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // Read the suite's OWN domain rather than the merged search list:
        // `AppleLanguages` lives in NSGlobalDomain, so a plain read falls back to
        // the system languages and would mask whether our override was removed.
        func suiteOverride() -> [String]? {
            defaults.persistentDomain(forName: suiteName)?[AppSettings.appleLanguagesKey] as? [String]
        }

        defaults.set(AppLanguage.english.rawValue, forKey: "MD2.Language")
        AppSettings.applyStoredLanguageOverride(defaults: defaults)
        #expect(suiteOverride() == ["en"])

        defaults.set(AppLanguage.zhHans.rawValue, forKey: "MD2.Language")
        AppSettings.applyStoredLanguageOverride(defaults: defaults)
        #expect(suiteOverride() == ["zh-Hans"])

        // Switching back to Follow System removes our override, so reads fall
        // back to the system languages (NSGlobalDomain) — i.e. follow system.
        defaults.set(AppLanguage.system.rawValue, forKey: "MD2.Language")
        AppSettings.applyStoredLanguageOverride(defaults: defaults)
        #expect(suiteOverride() == nil)
    }

    @Test func changingLanguagePreseedsAppleLanguagesForNextLaunch() {
        let suiteName = "MenuStartupTests-language-change-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        func suiteOverride() -> [String]? {
            defaults.persistentDomain(forName: suiteName)?[AppSettings.appleLanguagesKey] as? [String]
        }

        let settings = AppSettings(defaults: defaults)
        settings.language = .english
        #expect(suiteOverride() == ["en"])

        settings.language = .zhHans
        #expect(suiteOverride() == ["zh-Hans"])

        settings.language = .system
        #expect(suiteOverride() == nil)
    }

    // MARK: - Launch-gating preference (task 6.2)

    @Test func opensBlankDocumentOnLaunchDefaultsToFalse() {
        let settings = makeSettings()
        #expect(settings.opensBlankDocumentOnLaunch == false)
    }

    @Test func opensBlankDocumentOnLaunchPersistsAcrossInstances() {
        let suiteName = "MenuStartupTests-blank-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let first = AppSettings(defaults: defaults)
        first.opensBlankDocumentOnLaunch = true

        let second = AppSettings(defaults: defaults)
        #expect(second.opensBlankDocumentOnLaunch)
    }

    // MARK: - Print (task 6.3)

    @Test func printFlushesRenderAndLeavesDocumentStateUnchanged() {
        let printer = FakeDocumentPrinter()
        let store = DocumentStore(documentPrinterFactory: { printer })
        store.text = "# Print Me\n\nBody text."

        let fileURLBefore = store.fileURL
        let dirtyBefore = store.isDirty
        store.print()

        #expect(printer.printCallCount == 1)
        // The pending debounced render is flushed before printing, so the HTML
        // and outline reflect the latest text.
        #expect(printer.html?.contains("Print Me") == true)
        #expect(printer.outline?.map(\.title) == ["Print Me"])
        // Printing is a derived artifact: document state is untouched.
        #expect(store.fileURL == fileURLBefore)
        #expect(store.isDirty == dirtyBefore)
    }

    @Test func printIsNoOpWhileExportInFlight() {
        let exporter = DeferringFakePDFExporter()
        let printer = FakeDocumentPrinter()
        let store = DocumentStore(
            pdfDestinationPicker: { _ in URL(fileURLWithPath: "/tmp/menu-startup-out.pdf") },
            pdfExporterFactory: { _, _ in exporter },
            documentPrinterFactory: { printer }
        )

        store.exportPDF()
        #expect(exporter.exportCallCount == 1)

        // Export is in flight (exporter holds its completion), so print no-ops.
        store.print()
        #expect(printer.printCallCount == 0)

        exporter.finish()
        store.print()
        #expect(printer.printCallCount == 1)
    }

    @Test func exportIsNoOpWhilePrintInFlight() {
        let exporter = DeferringFakePDFExporter()
        let printer = FakeDocumentPrinter(completesImmediately: false)
        let store = DocumentStore(
            pdfDestinationPicker: { _ in URL(fileURLWithPath: "/tmp/menu-startup-out.pdf") },
            pdfExporterFactory: { _, _ in exporter },
            documentPrinterFactory: { printer }
        )

        store.print()
        #expect(printer.printCallCount == 1)

        // Print is in flight (printer holds its completion), so export no-ops.
        store.exportPDF()
        #expect(exporter.exportCallCount == 0)

        printer.finish()
        store.exportPDF()
        #expect(exporter.exportCallCount == 1)
    }

    // MARK: - Runtime bundle declares zh-Hans so AppleLanguages can localize menus

    @Test func runtimeBundleDeclaresChineseLocalization() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("MenuStartupTests-plist-\(UUID().uuidString)", isDirectory: true)
        let productDirectory = root.appendingPathComponent("Products", isDirectory: true)
        let executableURL = productDirectory.appendingPathComponent("Markdown2")
        let appURL = root.appendingPathComponent("Markdown2.app", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        try fileManager.createDirectory(at: productDirectory, withIntermediateDirectories: true)
        try "binary".write(to: executableURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)

        try RuntimeAppBundleBuilder().build(bundleURL: appURL, executableURL: executableURL)

        let plistURL = appURL.appendingPathComponent("Contents/Info.plist")
        let data = try Data(contentsOf: plistURL)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        let localizations = plist?["CFBundleLocalizations"] as? [String]
        #expect(localizations?.contains("zh-Hans") == true)
        #expect(localizations?.contains("en") == true)
    }
}

@MainActor
private final class FakeDocumentPrinter: DocumentPrinting {
    private(set) var printCallCount = 0
    private(set) var html: String?
    private(set) var outline: [Heading]?
    private(set) var baseURL: URL?
    private(set) var profile: ExportProfile?
    private let completesImmediately: Bool
    private var pendingCompletion: ((Result<Void, Error>) -> Void)?

    init(completesImmediately: Bool = true) {
        self.completesImmediately = completesImmediately
    }

    func print(
        html: String,
        outline: [Heading],
        baseURL: URL?,
        profile: ExportProfile,
        documentTitle: String,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        printCallCount += 1
        self.html = html
        self.outline = outline
        self.baseURL = baseURL
        self.profile = profile
        if completesImmediately {
            completion(.success(()))
        } else {
            pendingCompletion = completion
        }
    }

    func finish(_ result: Result<Void, Error> = .success(())) {
        pendingCompletion?(result)
        pendingCompletion = nil
    }
}

@MainActor
private final class DeferringFakePDFExporter: PDFExporting {
    private(set) var exportCallCount = 0
    private var pendingCompletion: ((Result<Void, Error>) -> Void)?

    func export(
        html: String,
        outline: [Heading],
        baseURL: URL?,
        documentTitle: String,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        exportCallCount += 1
        pendingCompletion = completion
    }

    func finish(_ result: Result<Void, Error> = .success(())) {
        pendingCompletion?(result)
        pendingCompletion = nil
    }
}
