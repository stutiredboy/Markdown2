import Foundation
import Testing
@testable import MD2App

@MainActor
struct TypographySettingsTests {
    @Test func preferencesPersistAndZoomIsBounded() throws {
        let name = "TypographySettingsTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        #expect(settings.typography.readingWidth == .comfortable)
        settings.typography.editorFont = .monospaced
        settings.typography.readingFont = .serif
        settings.typography.fontSize = 20
        settings.typography.readingWidth = .narrow
        settings.zoomIn()
        #expect(settings.typography.effectiveFontSize == 22)
        #expect(AppSettings(defaults: defaults).typography == settings.typography)
        for _ in 0..<30 { settings.zoomIn() }
        #expect(settings.typography.zoomPercent == 200)
        for _ in 0..<30 { settings.zoomOut() }
        #expect(settings.typography.zoomPercent == 50)
        settings.resetZoom()
        #expect(settings.typography.zoomPercent == 100)
        #expect(settings.typography.fontSize == 20)
    }

    @Test func invalidPersistedSizesCannotBreakLayout() {
        var value = TypographySettings()
        value.zoom = .infinity
        value.fontSize = -100
        #expect(value.normalized.zoom == 1)
        #expect(value.normalized.fontSize == 12)
    }

    @Test func readingWidthSelectionsUseDistinctLocalizedLabelsAndPreserveOtherTypography() throws {
        let name = "ReadingWidthSettingsTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        settings.typography.fontSize = 22
        settings.typography.readingFont = .serif
        settings.zoomIn()

        for width in ReadingWidth.allCases {
            settings.typography.readingWidth = width
            let reopened = AppSettings(defaults: defaults).typography
            #expect(reopened.readingWidth == width)
            #expect(reopened.fontSize == 22)
            #expect(reopened.readingFont == .serif)
            #expect(reopened.zoomPercent == 110)
            #expect(settings.typography.previewCSS.contains("max-width: \(width.css)"))
        }

        for language in [AppLanguage.english, .zhHans] {
            let labels = ReadingWidth.allCases.map { L10n.text($0.label, language: language) }
            #expect(Set(labels).count == 4)
            #expect(L10n.hasTranslation(.readingWidthHelp, language: language))
        }
    }

    @Test func zoomKeysCannotBeAssignedToModes() {
        for shortcut in [ModeKeyboardShortcut.command("+"), .command("="), .command("-"),
                         ModeKeyboardShortcut(key: "0", modifiers: [.command, .option]),
                         ModeKeyboardShortcut(key: "=", modifiers: [.command, .shift])] {
            #expect(ModeShortcutValidator.validate(shortcut, for: .write, in: .default) != nil)
        }
    }
}
