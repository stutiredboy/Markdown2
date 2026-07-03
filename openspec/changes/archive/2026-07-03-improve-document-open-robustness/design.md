## Context

`DocumentStore.load(from:)` calls `String(contentsOf:encoding:.utf8)` and funnels any thrown error into `DocumentAlert` with hard-coded English copy. `DocumentAlert` is also built with English literals at seven other sites (save, PDF/HTML/DOCX/EPUB export, print, Pandoc availability, attachment write). The app's localization lives in `L10n`/`L10nKey` behind `AppSettings.text(_:)`, `@MainActor`, and `DocumentStore` currently has no settings reference — it receives injected providers (export profile, render config) from the app delegate instead.

## Goals / Non-Goals

**Goals:**
- Open the encodings that occur in practice for Markdown notes (UTF-8 with/without BOM, UTF-16/32 with BOM, GB18030 which supersets GBK/GB2312) without user configuration.
- Keep save behavior byte-stable for existing UTF-8 documents; converting fallback-decoded files to UTF-8 on save is deliberate and documented.
- One localization path for every document alert; no English literals left in `DocumentStore`.

**Non-Goals:**
- No encoding picker UI, no per-document encoding persistence, no re-save in the original encoding (UTF-8 is the app's storage format).
- No statistical charset detection (`NSString.stringEncoding(for:)`'s full heuristics or ICU detection) — a fixed, predictable fallback list is easier to reason about and test.
- No localization of strings outside document alerts (menus/settings are already localized).

## Decisions

- **Fixed fallback order: BOM first, then UTF-8, then GB18030.** A BOM (UTF-8/UTF-16LE/BE/UTF-32LE/BE) is authoritative when present. Otherwise strict UTF-8 decode is attempted — UTF-8 false-positives are practically impossible for real GB-encoded text of meaningful length. Then GB18030 (covers GBK/GB2312 byte-compatibly). If all fail, report undecodable. Rationale: deterministic, covers the user base (bilingual EN/zh-Hans app), and each step is exact-decode, not a guess. Alternative considered: `NSString(contentsOf:usedEncoding:)` — rejected: its attempt order is opaque and can mis-pick Latin-1-style encodings, silently mojibake-ing GB files.
- **Decode returns the text plus the encoding used; the store keeps only a "was converted" fact.** No behavior depends on the original encoding beyond an accurate mental model — save always writes UTF-8 (unchanged from today). We do not warn on save: silently normalizing to UTF-8 matches Typora/VS Code default behavior and avoids a nagging dialog. The decode helper is a pure `enum MarkdownFileDecoder` in MD2App with byte-fixture tests.
- **Localize alerts via an injected provider, mirroring the existing pattern.** `DocumentStore` gains `alertTextProvider: @MainActor (DocumentAlertKey) -> String` (defaulting to the English table so existing tests keep passing), wired by `MD2AppDelegate` to `settings.text(_:)`. Alert construction switches to keyed messages with the file name / format interpolated via `String(format:)`. The system error's `localizedDescription` stays in `detail` — it is diagnostic, OS-localized already, and useful in reports. Alternative considered: passing `AppSettings` into the store — rejected: couples the store to the whole settings object and complicates tests.
- **New keys** cover: could-not-open, could-not-decode (encoding-specific message), could-not-save, could-not-export (shared by PDF/HTML/DOCX/EPUB with the file name interpolated), could-not-print, pandoc-required (message + guidance detail), attachment-save-failed. Chinese copy follows the existing table's tone (short, imperative).

## Risks / Trade-offs

- [GB18030 decodes almost any byte sequence, so binary files may "succeed" into garbage text] → gate the GB18030 fallback with a cheap plausibility check (reject if the decoded text contains NUL/control characters outside tab/newline); undecodable then reports the clear localized message. Covered by a binary-fixture test.
- [A UTF-16 file *without* BOM will fail UTF-8 and likely be rejected by the plausibility check] → acceptable: BOM-less UTF-16 Markdown is vanishingly rare on macOS; the failure message now says the encoding is the problem, which is actionable.
- [Converting GB files to UTF-8 on save changes bytes for outside tools] → intended and industry-standard; noted in the spec so it is a tested, documented behavior rather than an accident.
- [Format-string localization (`%@` ordering) differs between languages] → use positional format specifiers and add a test that formats every parameterized alert string in both languages.

## Open Questions

- None. Big5/Shift-JIS fallbacks can be appended to the decoder list later without spec changes beyond a scenario addition.
