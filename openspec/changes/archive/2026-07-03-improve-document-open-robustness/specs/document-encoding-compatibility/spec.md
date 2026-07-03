## ADDED Requirements

### Requirement: Opening decodes common text encodings with a fixed fallback order
WHEN opening a Markdown file, the app SHALL decode it by trying, in order: a Unicode byte-order mark (UTF-8, UTF-16LE/BE, UTF-32LE/BE) when present, then strict UTF-8, then GB18030 (which covers GBK and GB2312). A GB18030 fallback result SHALL be rejected when it contains control characters other than tab, newline, and carriage return, so binary files do not open as garbage text. The first successful decode SHALL populate the editor exactly as a UTF-8 load does today.

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

### Requirement: Saves write UTF-8
The app SHALL always write documents as UTF-8. A document that was opened via a fallback encoding SHALL be converted to UTF-8 by its next save; documents opened as UTF-8 SHALL remain byte-stable apart from the user's edits.

#### Scenario: Fallback-decoded file saves as UTF-8
- **WHEN** a GB18030-decoded document is saved
- **THEN** the file on disk is written in UTF-8 with the same textual content
