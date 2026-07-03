## Why

Opening a file is hard-coded to UTF-8: a Markdown file saved as GB18030/GBK (common for Chinese users' legacy notes), Big5, or UTF-16 fails with a raw Foundation error. And every document-level failure alert (`Could not open…`, `Could not save…`, `Could not export…`, `Pandoc is required…`, image-attachment failures) is hard-coded English while the rest of the UI is fully bilingual — a Simplified-Chinese user sees mixed-language errors at exactly the moments that need clarity.

## What Changes

- Open attempts UTF-8 first, then falls back through BOM-detected UTF-16/UTF-32 and GB18030 before failing; the decoded text is normalized into the editor as today.
- Saving always writes UTF-8 (current behavior, now explicit); a document opened via a fallback encoding is therefore converted to UTF-8 on its next save.
- When every encoding attempt fails, the alert states clearly — in the app language — that the file could not be decoded as text, instead of surfacing a raw Foundation error string.
- All `DocumentAlert` copy (open/save/export/print/Pandoc/attachment failures) moves into the `L10n` table with English and Simplified Chinese strings; underlying system error details remain appended for diagnostics.

## Capabilities

### New Capabilities
- `document-encoding-compatibility`: Which text encodings the app can open, the fallback order, and how saves normalize to UTF-8.
- `document-alert-localization`: All document-level failure alerts render their message and button copy in the app language.

### Modified Capabilities

## Impact

- `Sources/MD2App/DocumentStore.swift`: encoding-fallback decode in `load(from:)`; all alert construction goes through localized strings (store gains access to a localization provider, injected like the existing settings providers).
- `Sources/MD2App/AppSettings.swift`: new `L10nKey` cases and English/Chinese strings for alert copy and the undecodable-file message.
- Tests: decode-fallback unit tests with fixture bytes (UTF-8, UTF-8+BOM, UTF-16LE/BE with BOM, GB18030, undecodable binary); alert copy sourced from the table for both languages.
