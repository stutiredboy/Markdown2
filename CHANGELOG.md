# Changelog

## Unreleased

### Added

- Star the current folder in the browser and reopen it across launches from File → Favorite Folders. Remove individual favorites or clear the list from the same menu.

- Allow remote images for verified Markdown files in the current folder and its subfolders. Favorite folders remember their authorization, and individual files can opt out during the session.

### Changed

- Browse files in a collapsible Files and Outline sidebar. Click a file or use Up and Down in the tree to skim in one native preview tab. Double-click, press Return, or edit to keep the file open as a regular tab. Return to the tree with Shift+Cmd+B. Folder indexing now refreshes on filesystem changes or on request.

### Fixed

- Open folders to the file tree and an empty document area when no document is selected. The first file takes over the window without creating an Untitled tab.

## 0.9.0 - 2026-11-19

### Added

- Browse an explicitly selected Markdown folder with File → Open Folder and jump to indexed files by name or relative path with Quick Open.
- Browse saved revisions from File → Browse Local History and open a selected revision as a separate copy.
- Copy pasted or dropped images into a document-relative folder, link to the originals, or collect existing local images. Use Create Copy to open a separate Markdown file beside the original.
- Find with case and whole-word options in the editor or preview, and replace within a selected source range.
- Turn on regular expressions in the source find bar to search Markdown and reuse capture groups in replacements. Replace All shows the scope and count and can be undone in one step.
- Edit source tables from the keyboard or Format menu. The Edit menu offers explicit paste as Markdown, Table, or Plain Text.
- Edit a standalone single-line `$$…$$` formula directly in Preview. The change preserves surrounding Markdown and can be undone in one step. Other formula forms can be opened in source.
- Control remote images per document session and inspect the referenced origins. Offline HTML exports embed validated local images and show placeholders for omitted images.
- Export the current Markdown to DOCX or EPUB from File → Export To with a locally installed Pandoc. The save panel explains conversion limits, and the status bar lets you cancel while conversion runs.
- Keep your source selection and position when switching modes. Use Typewriter Scrolling to keep the caret near the center while writing. Native controls have improved keyboard, Simplified Chinese Pinyin, and VoiceOver support.

### Fixed

- Save to a new location when the original file is replaced by an unreadable or nonregular entry. Hard-linked files keep their existing contents when recovery cannot be written, and manual Save explains the failure.
- Protect the open Markdown source from being overwritten by HTML or PDF export.
- Keep literal Replace All responsive in documents with many matches while preserving a single Undo step.
- Reduce source styling delays when opening large documents and keep the editor responsive during coloring.
- Switch modes in large documents without wrapping the source at a temporary zero width. Keep the source column usable at maximum zoom in a narrow pane.
- Preserve ordered-list numbering, links with balanced parentheses, fenced code languages, and headings next to tables in rendered output. PDF export preserves square-root signs.
- Keep Find and Replace usable in narrow editor panes and preserve the search when switching modes.
- Show deeply nested Markdown as source if it exceeds the rendering limits. Standalone HTML embeds only validated local images and reports omitted images.

### Changed

- The app and standalone HTML exports carry the license notices for the third-party resources they distribute.
- Local packaging uses a separate development identity by default. Installing an app and setting it as the default Markdown editor are explicit options.
