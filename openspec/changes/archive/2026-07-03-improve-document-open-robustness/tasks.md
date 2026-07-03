## 1. Encoding Decoder

- [x] 1.1 Add `MarkdownFileDecoder`: BOM detection (UTF-8/16LE/16BE/32LE/32BE) → strict UTF-8 → GB18030 with the control-character plausibility gate; returns text + whether a fallback was used.
- [x] 1.2 Unit tests with byte fixtures: UTF-8, UTF-8+BOM, UTF-16LE/BE with BOM, GB18030 Chinese text, binary rejection, empty file.
- [x] 1.3 Use the decoder in `DocumentStore.load(from:)`; keep the save path writing UTF-8 and add a round-trip test (GB18030 open → save → UTF-8 bytes).

## 2. Alert Localization

- [x] 2.1 Add `L10nKey` cases and EN/zh-Hans strings for: open failure, undecodable file, save failure, export failure (file-name parameterized), print failure, Pandoc required (message + detail), attachment save failure.
- [x] 2.2 Inject an alert-text provider into `DocumentStore` (defaulting to the English table); wire it to `settings.text(_:)` in `MD2AppDelegate`; replace all hard-coded alert literals.
- [x] 2.3 Test that every parameterized alert string formats correctly in both languages and that a store built with an injected provider uses it.

## 3. Verification

- [x] 3.1 Run `swift test` and build the app.
- [x] 3.2 Manual pass in Simplified Chinese: open a GBK fixture (opens readably), open a binary file (clear localized message), trigger a save failure (read-only target) and DOCX export without Pandoc — all alerts in Chinese; repeat one alert in English.
