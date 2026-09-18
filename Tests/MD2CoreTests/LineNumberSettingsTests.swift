import Foundation
import Testing
@testable import MD2App

/// The two line-number scopes are independent display preferences: both default
/// to off, enabling one never touches the other, both can be on at once, and the
/// choice survives a relaunch. Nothing here needs a window, so these run in the
/// default `swift test` suite.
@MainActor
struct LineNumberSettingsTests {
    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "LineNumberSettingsTests-\(UUID().uuidString)")!
    }

    private func makeIsolatedDefaults(_ label: String) -> (UserDefaults, String) {
        let name = "LineNumberSettingsTests-\(label)-\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    @Test func bothScopesDefaultToOff() {
        let settings = AppSettings(defaults: makeDefaults())

        #expect(settings.showsLineNumbersInEditor == false)
        #expect(settings.showsLineNumbersInPreview == false)
    }

    @Test func scopesAreIndependent() {
        let settings = AppSettings(defaults: makeDefaults())

        settings.showsLineNumbersInEditor = true

        #expect(settings.showsLineNumbersInEditor)
        #expect(settings.showsLineNumbersInPreview == false)
    }

    @Test func bothScopesCanBeOnAtOnce() {
        let settings = AppSettings(defaults: makeDefaults())

        settings.showsLineNumbersInEditor = true
        settings.showsLineNumbersInPreview = true

        #expect(settings.showsLineNumbersInEditor)
        #expect(settings.showsLineNumbersInPreview)
    }

    @Test func turningOneOffLeavesTheOtherOn() {
        let settings = AppSettings(defaults: makeDefaults())
        settings.showsLineNumbersInEditor = true
        settings.showsLineNumbersInPreview = true

        settings.showsLineNumbersInPreview = false

        #expect(settings.showsLineNumbersInEditor)
        #expect(settings.showsLineNumbersInPreview == false)
    }

    @Test func choicesPersistAcrossInstances() {
        let (defaults, name) = makeIsolatedDefaults("persist")
        defer { defaults.removePersistentDomain(forName: name) }

        let settings = AppSettings(defaults: defaults)
        settings.showsLineNumbersInEditor = true
        settings.showsLineNumbersInPreview = false

        let reloaded = AppSettings(defaults: defaults)

        #expect(reloaded.showsLineNumbersInEditor)
        #expect(reloaded.showsLineNumbersInPreview == false)
    }

    @Test func anExplicitlyStoredFalseIsPreserved() {
        // A stored `false` must not be mistaken for "no preference"; the init
        // branches on key presence (`object(forKey:)`), not on the bool value.
        let (defaults, name) = makeIsolatedDefaults("explicit-false")
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(false, forKey: "MD2.ShowsLineNumbersInEditor")

        let settings = AppSettings(defaults: defaults)

        #expect(settings.showsLineNumbersInEditor == false)
    }

    @Test func storedKeysAreStable() {
        // The keys are a persistence contract: renaming one silently resets every
        // existing user's preference, so pin them.
        let (defaults, name) = makeIsolatedDefaults("keys")
        defer { defaults.removePersistentDomain(forName: name) }

        let settings = AppSettings(defaults: defaults)
        settings.showsLineNumbersInEditor = true
        settings.showsLineNumbersInPreview = true

        #expect(defaults.bool(forKey: "MD2.ShowsLineNumbersInEditor"))
        #expect(defaults.bool(forKey: "MD2.ShowsLineNumbersInPreview"))
    }
}
