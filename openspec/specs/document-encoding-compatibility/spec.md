# document-encoding-compatibility Specification

## Purpose

Define which text encodings the app can open (BOM-marked Unicode forms, UTF-8, GB18030 with a plausibility gate), the fixed fallback order, and how saves preserve encoding, BOM, and line endings.

## Requirements
### Requirement: Opening decodes common text encodings with a fixed fallback order
WHEN opening a Markdown file, the app SHALL decode it by trying, in order: a Unicode byte-order mark (UTF-8, UTF-16LE/BE, UTF-32LE/BE) when present, then strict UTF-8, then GBK, then GB18030. Each decode SHALL round-trip to the exact original bytes without lossy conversion. A GB18030 fallback result SHALL be rejected when it contains control characters other than tab, newline, and carriage return, so binary files do not open as garbage text. The first successful decode SHALL populate the editor exactly as a UTF-8 load does today.

#### Scenario: UTF-8 file opens unchanged
- **WHEN** the user opens a UTF-8 file (with or without BOM)
- **THEN** the document opens with its content intact

#### Scenario: GBK/GB18030 file opens readably
- **WHEN** the user opens a Markdown file saved in GBK/GB18030 containing Chinese text
- **THEN** the document opens with the Chinese text decoded correctly instead of failing

#### Scenario: UTF-16 file with BOM opens readably
- **WHEN** the user opens a UTF-16 file that begins with a byte-order mark
- **THEN** the document opens with its content decoded correctly

#### Scenario: Binary file is rejected clearly
- **WHEN** the user opens a file whose bytes cannot be decoded as text under the fallback order
- **THEN** the document does not open
- **AND** the failure alert states, in the app language, that the file could not be read as text

### Requirement: Saves preserve the original byte format
The app SHALL retain the detected encoding, BOM presence, and line endings through manual saves, autosaves, external reloads, and recovery. New line breaks in a uniformly LF/CRLF/CR document SHALL use its existing convention. Mixed line endings SHALL not be normalized. The status bar SHALL display the current format.

#### Scenario: GBK file remains compatible with GBK readers
- **WHEN** a GBK-decoded document is edited and saved
- **THEN** representable characters are written as GBK, with the original BOM policy and newline convention

#### Scenario: Unrepresentable characters require explicit conversion
- **WHEN** an edit contains characters the current encoding cannot represent
- **THEN** the backing file is left unchanged and a localized prompt offers conversion to UTF-8 or cancellation
- **AND** cancellation retains the edits in memory and in the recovery copy
- **AND** automatic saves do not repeatedly present the same unanswered or cancelled conversion choice

#### Scenario: BOM and byte order survive saving
- **WHEN** a UTF-16/UTF-32 file with BOM is saved
- **THEN** it retains that BOM and byte order
