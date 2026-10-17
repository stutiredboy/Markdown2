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

    @Test func zoomKeysCannotBeAssignedToModes() {
        for shortcut in [ModeKeyboardShortcut.command("+"), .command("="), .command("-"),
                         ModeKeyboardShortcut(key: "0", modifiers: [.command, .option]),
                         ModeKeyboardShortcut(key: "=", modifiers: [.command, .shift])] {
            #expect(ModeShortcutValidator.validate(shortcut, for: .write, in: .default) != nil)
        }
    }
}
