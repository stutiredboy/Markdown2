import Foundation
import Testing
@testable import MD2App

@MainActor
struct AppSettingsPresentationModeTests {
    private func makeSettings() -> AppSettings {
        let defaults = UserDefaults(suiteName: "AppSettingsPresentationModeTests-\(UUID().uuidString)")!
        return AppSettings(defaults: defaults)
    }

    @Test func fileBackedDocumentsUseDefaultMode() {
        let settings = makeSettings()
        settings.defaultMode = .read
        settings.newDocumentMode = .write

        #expect(settings.presentationMode(isFileBacked: true) == .read)
    }

    @Test func newDocumentsUseNewDocumentMode() {
        let settings = makeSettings()
        settings.defaultMode = .read
        settings.newDocumentMode = .write

        #expect(settings.presentationMode(isFileBacked: false) == .write)
    }

    @Test func newDocumentModeDefaultsToEditWhenUnset() {
        let settings = makeSettings()

        #expect(settings.newDocumentMode == .write)
        #expect(settings.presentationMode(isFileBacked: false) == .write)
    }

    @Test func newDocumentModeDoesNotAffectOpenedFileMode() {
        let settings = makeSettings()
        settings.newDocumentMode = .read

        #expect(settings.defaultMode == .write)
        #expect(settings.presentationMode(isFileBacked: true) == .write)
    }

    @Test func existingOpenedFileModePreferenceIsPreserved() {
        let suiteName = "AppSettingsPresentationModeTests-existing-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(EditorMode.read.rawValue, forKey: "MD2.DefaultMode")

        let settings = AppSettings(defaults: defaults)

        #expect(settings.defaultMode == .read)
        #expect(settings.newDocumentMode == .write)
        #expect(settings.presentationMode(isFileBacked: true) == .read)
        #expect(settings.presentationMode(isFileBacked: false) == .write)
    }

    @Test func newDocumentModePersistsAcrossInstances() {
        let suiteName = "AppSettingsPresentationModeTests-persist-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let first = AppSettings(defaults: defaults)
        first.newDocumentMode = .read

        let second = AppSettings(defaults: defaults)
        #expect(second.newDocumentMode == .read)
    }

    @Test func sideBySideModePersistsForBothPreferences() {
        let suiteName = "AppSettingsPresentationModeTests-split-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let first = AppSettings(defaults: defaults)
        first.defaultMode = .split
        first.newDocumentMode = .split

        let second = AppSettings(defaults: defaults)
        #expect(second.defaultMode == .split)
        #expect(second.newDocumentMode == .split)
        #expect(second.presentationMode(isFileBacked: true) == .split)
        #expect(second.presentationMode(isFileBacked: false) == .split)
    }

    @Test func unknownStoredModeFallsBackToEdit() {
        let suiteName = "AppSettingsPresentationModeTests-unknown-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("nonsense", forKey: "MD2.DefaultMode")

        let settings = AppSettings(defaults: defaults)
        #expect(settings.defaultMode == .write)
    }

    @Test func modeShortcutsDefaultToCommandNumberKeys() {
        let settings = makeSettings()

        #expect(settings.modeShortcuts[.write] == .command("1"))
        #expect(settings.modeShortcuts[.read] == .command("2"))
        #expect(settings.modeShortcuts[.split] == .command("3"))
    }

    @Test func modeShortcutChangesPersistAcrossInstances() {
        let suiteName = "AppSettingsPresentationModeTests-shortcuts-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let first = AppSettings(defaults: defaults)
        let custom = ModeKeyboardShortcut(key: "2", modifiers: [.command, .option])
        #expect(first.updateModeShortcut(custom, for: .read) == nil)

        let second = AppSettings(defaults: defaults)
        #expect(second.modeShortcuts[.read] == custom)
        #expect(second.modeShortcuts[.write] == .command("1"))
        #expect(second.modeShortcuts[.split] == .command("3"))
    }

    @Test func invalidStoredModeShortcutConfigurationFallsBackToDefaults() throws {
        let suiteName = "AppSettingsPresentationModeTests-invalid-shortcuts-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let invalid = ModeShortcutConfiguration(
            edit: .command("1"),
            preview: .command("1"),
            sideBySide: .command("3")
        )
        defaults.set(try JSONEncoder().encode(invalid), forKey: "MD2.ModeShortcuts")

        let settings = AppSettings(defaults: defaults)
        #expect(settings.modeShortcuts == .default)
    }

    @Test func malformedStoredModeShortcutConfigurationFallsBackToDefaults() {
        let suiteName = "AppSettingsPresentationModeTests-malformed-shortcuts-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(Data("not-json".utf8), forKey: "MD2.ModeShortcuts")

        let settings = AppSettings(defaults: defaults)
        #expect(settings.modeShortcuts == .default)
    }

    @Test func duplicateModeShortcutIsRejectedAndPreviousValueRemains() {
        let settings = makeSettings()

        let error = settings.updateModeShortcut(.command("1"), for: .read)

        #expect(error == .duplicate(existingMode: .write))
        #expect(settings.modeShortcuts[.read] == .command("2"))
    }

    @Test func appCommandModeShortcutIsRejectedAndPreviousValueRemains() {
        let settings = makeSettings()

        let error = settings.updateModeShortcut(.command("s"), for: .write)

        #expect(error == .appCommand(commandName: "Save"))
        #expect(settings.modeShortcuts[.write] == .command("1"))
    }

    @Test func systemReservedModeShortcutIsRejectedAndPreviousValueRemains() {
        let settings = makeSettings()

        let error = settings.updateModeShortcut(ModeKeyboardShortcut(key: "space", modifiers: [.command]), for: .read)

        #expect(error == .systemReserved(reason: "Spotlight"))
        #expect(settings.modeShortcuts[.read] == .command("2"))
    }
}
