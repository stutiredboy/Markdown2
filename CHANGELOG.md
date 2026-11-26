# Changelog

## Unreleased

### Added

- Pause synchronized scrolling in a Side by Side window to keep a table in view while writing. Resume from either pane to align the other with it.

- Compare the editor and disk versions side by side when another app changes a document with unsaved edits. Save the editor draft as a separate copy, keep it in the original, or reload the disk version. Autosave waits for your decision.

- Open a wide Mermaid diagram at its actual size in the preview, pan to read its labels, and press Esc to return to the same reading position.

- Command-double-click a passage in Preview or choose **Edit This Paragraph in Source** from its context menu to place the caret in the corresponding source block.

- Change the reading width from the preview toolbar or the View menu. In Preview, the outline appears in the right margin when there is room and the left outline is hidden.

- Star the current folder in the browser and reopen it across launches from File → Favorite Folders. Remove individual favorites or clear the list from the same menu.

- Allow remote images for verified Markdown files in the current folder and its subfolders. Favorite folders remember their authorization, and individual files can opt out during the session.

### Changed

- Use Write or Read in a 720 pt window. The sidebar makes room for the document, and long inline code wraps to fit the preview.

- The status bar shows word count and reading time in Read, and the cursor position and selection counts in Write. Open **Document Info** for the full path, encoding, and line endings.

- Use a new paper-and-ink macOS app icon with an amber 2.

- Open independent documents together in native tabs, separate from the folder browser. Turn off **Prefer Tabs for Documents** in General settings to open them in separate windows.

- Show a banner when remote images are detected and the document policy blocks loading. When allowed, use the green globe in the status bar to check the source of permission, revoke it or inspect image origins. **View → Remote Images** also provides the document controls. The Files sidebar shows the folder permission.

- Browse files in a collapsible Files and Outline sidebar. Click a file or use Up and Down in the tree to skim in one native preview tab. Choose **Keep Document Open ↵**, press Return, double-click, or edit the file to keep it open as a regular tab. Return to the tree with Shift+Cmd+B. Folder indexing now refreshes on filesystem changes or on request.

### Fixed

- See that autosave is paused in the status bar after choosing **Later**, and reopen the conflict comparison from there. Selection statistics and export interruption messages remain readable in a 720 pt window.

- Find text inside author highlights in the preview. Navigating to a result inside a collapsed disclosure opens it and reveals the match.

- Wrap long plain-text tokens and automatic links in narrow previews. Wide tables and fenced code scroll within their own blocks.

- Count each discontiguous source selection separately and show the number of selected ranges in the status bar.

- Open the corresponding source line when Command-double-clicking an HTML block or the plain text immediately after it in Preview, or choosing **Edit This Paragraph in Source** from its context menu.

- Keep every preview Find result visible when navigating between an actual-size Mermaid diagram and the document text.

- Keep the document marked as unsaved after **Keep My Version** until the chosen editor version is saved to the original file.

- Keep the current Find result, visible list item and visible part of a local image in place when editing with synchronized scrolling paused. The visible table row stays in place when inserting rows or growing the header.

- Give the preview Find bar its own space in Read and Side by Side. Matches keep the original line breaks, use contrasting text in both appearances and outline the current result.

- Preserve outer borders and inner row and column lines in tables exported to DOCX.

- Refresh document commands when a document opens, the active window changes, or the last document closes. Find the file browser controls under View and switch modes with Control+Command+1, 2, or 3 by default.

- Register Markdown variants including `.mdown` and `.mkd`. The packaged app offers to open plain text as an alternate editor.

- Clean up installation staging on interruption and restore the previous app if replacement was interrupted before the new copy was in place.

- Recover an interrupted save from either hard-linked filename. Review the draft before choosing **Finish Save** to update the linked file.

- Restore the reading position and selection in large source documents while laying out only as much wrapped text as the destination needs. Positions near the end still use the measured document height.

- Show the filename in the title bar when the tab bar is hidden and on the tab when it is shown. The first folder preview uses the single-document title bar, and a second document reveals the tabs.

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
