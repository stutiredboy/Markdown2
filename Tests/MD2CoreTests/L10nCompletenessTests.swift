import Foundation
import Testing
@testable import MD2App

/// `L10n.text` falls back silently — `zhHans[key] ?? english[key] ?? key.rawValue`
/// — so a key added to the enum without a table entry ships as English text to
/// Chinese users, and a key missing from both ships the raw enum string into the
/// UI. Neither is a compile error, so this test is the guard: every case must
/// resolve in every authored language.
struct L10nCompletenessTests {
    @Test func everyKeyHasAnEnglishEntry() {
        let missing = L10nKey.allCases.filter { !L10n.hasTranslation($0, language: .english) }

        #expect(missing.isEmpty, "Missing English strings: \(missing.map(\.rawValue))")
    }

    @Test func everyKeyHasASimplifiedChineseEntry() {
        let missing = L10nKey.allCases.filter { !L10n.hasTranslation($0, language: .zhHans) }

        #expect(missing.isEmpty, "Missing Simplified Chinese strings: \(missing.map(\.rawValue))")
    }

    @Test func lineNumberKeysResolveInBothLanguages() {
        // Spot-check that the new keys are not merely present but distinct from
        // the silent fallback (a raw enum string) in each language.
        let keys: [L10nKey] = [.lineNumbers, .lineNumbersInEditor, .lineNumbersInPreview, .lineNumbersHelp]

        for key in keys {
            for language in [AppLanguage.english, .zhHans] {
                let text = L10n.text(key, language: language)
                #expect(!text.isEmpty)
                #expect(text != key.rawValue, "\(key.rawValue) has no \(language) string")
            }
        }
    }
}
