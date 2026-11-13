<div align="center">
  <h1>Markdown2</h1>
  <p><strong>Markdown Editor Too</strong> — a lightweight native macOS Markdown editor & reader</p>
  <p><a href="README.zh-CN.md">[中文]</a> [English]</p>

  <p>
    <a href="https://github.com/stutiredboy/md2/stargazers"><img src="https://img.shields.io/github/stars/stutiredboy/md2?style=social" alt="GitHub stars"></a>
    <a href="https://github.com/stutiredboy/md2/blob/main/LICENSE"><img src="https://img.shields.io/github/license/stutiredboy/md2" alt="License"></a>
    <a href="https://github.com/stutiredboy/md2/releases"><img src="https://img.shields.io/github/v/release/stutiredboy/md2" alt="Latest release"></a>
  </p>

  <p>Inspired by Typora's minimal writing flow, Markdown2 keeps the distraction-free experience in a compact, native macOS app built with SwiftUI + AppKit.</p>
</div>

## Features

- **Three presentation modes** — `Write`, `Read`, and `Side by Side` (split editor + live preview).
- **Native AppKit text editing** with lightweight Markdown styling.
- **Markdown-aware editing** — Return continues lists, tasks, and quotes; Return on an empty item exits it. `Shift+Return` continues at the content column, and `Tab` / `Shift+Tab` adjust list nesting. Brackets, quotes, and backticks pair automatically, with closing-character skip and paired Backspace.
- **Source table editing** — `Tab` / `Shift+Tab` move between cells in supported top-level tables; Tab at the last cell adds a row. Format > Table Operations inserts or deletes rows and columns, preserving existing cell text and alignment with one-step Undo.
- **Explicit paste** — choose Plain Text (`Option+Shift+Cmd+V`), Markdown from supported HTML/RTF, or Table from TSV in Edit. Ordinary `Cmd+V` keeps its existing behavior. Rich conversion does not fetch clipboard resources; unsupported content offers a clearly reported literal-text fallback only where it can be inserted safely. See [paste behavior and limits](Docs/MarkdownEditing.md#explicit-paste).
- **Live-rendered HTML** reading mode.
- **Outline sidebar** generated from headings, with the current section following the top visible source line in Edit, Preview, and Side by Side.
- **Document recovery and format preservation**: follow Finder renames/moves, preserve encoding/BOM/line endings, autosave after 5 seconds idle or 30 seconds of continuous editing, and restore windows and untitled drafts on ordinary app launch. Opening a specific file restores only that file's draft; other recovery records are retained. Explicit close still confirms unsaved changes. See [document lifecycle](Docs/DocumentLifecycle.md).
- **Create Copy** — save the current editor text as a new Markdown file beside the original, preserving encoding and line endings, then open it independently. The original stays open with its own edits and undo history. Copies share existing attachments; attachment files are not duplicated.
- **Multi-window support** — each document opens in its own window; untouched starter windows are reused when opening files from Finder or the open panel.
- **Word, character, line, and reading-time** status bar. Counts rendered text with one unit per Han character and word boundaries for other text; selecting text in either pane shows selection / document counts.
- **Zoom and typography** — `Cmd++` / `Cmd+=`, `Cmd+-`, and `Option+Cmd+0`; separate editor/reading font choices, base font size, and four reading widths in Settings. The preview defaults to 800px. These display preferences persist without changing exports. See [reading preferences](Docs/ReadingPreferences.md).
- **Rich Markdown rendering** — headings, paragraphs, emphasis, links, images, blockquotes, horizontal rules, ordered/unordered/task lists, tables, fenced code with syntax highlighting, YAML front matter, and `[TOC]`.
- **Math typesetting** — inline `$...$` and display `$$...$$` TeX rendered offline with bundled [KaTeX](https://katex.org/) (no network required), including the mhchem extension for chemistry (`\ce{...}`).
- **Diagrams** — `mermaid`, `flow` ([flowchart.js](https://flowchart.js.org/)), and `sequence` ([js-sequence-diagrams](https://bramp.github.io/js-sequence-diagrams/)) code blocks rendered offline with bundled engines (no network required).
- **Footnotes** — `[^id]` inline references rendered as numbered superscript links; `[^id]: text` definitions collected into a trailing footnotes section with back-references. Supports named labels, multi-line definitions, duplicate references, and graceful fallback for undefined labels. Offline-rendered, legible in both light and dark modes.
- **Portable image attachments** — pasted screenshots and dropped/pasted image files are copied into a configurable, document-relative folder (default `assets/`). Settings also offers linking image files at their original location. Collect Local Images gathers safely recognized Markdown image references and reports missing, invalid and unsupported resources; see [supported collection syntax](Docs/PortableAttachments.md). Size images with Pandoc-style `{width=480}` / `{width=320 height=180}` attributes; missing local images show an explicit broken-image placeholder in the preview.
- **Export & print** — export the rendered document as a paginated PDF with a navigable heading outline (bookmark tree), or print it. A configurable **export profile** controls page size (A4 / Letter / Legal), orientation (portrait / landscape), margins (Normal / Narrow / Wide / None, or custom), and optional page numbers and header/footer text with `{title}`, `{date}`, `{page}`, and `{pageCount}` tokens — defaults stay A4 portrait with narrow (~0.5") margins, so existing output is unchanged. Diagrams render in exported and printed output, matching the preview.
- **Remote-image control** — automatic remote resources are blocked by default. Explicitly allow HTTP(S) images for one document window and session, then revoke at any time; preview, PDF and Print use that permission. Remote scripts, styles, fonts and other resource types remain blocked. See [resource policy and export limits](Docs/RemoteResources.md).
- **Export as HTML** — export an offline `.html` file with bundled styles, math/diagram engines and validated embedded images. Remote and unembeddable images become readable placeholders with an export notice, even when the preview allows remote images. Images generated inside diagrams are omitted while supported vector styles remain. DOCX/EPUB backends deny network access during conversion; their commands are not yet exposed in the menu.
- **Quick mode switching** — press `Esc` in the editor to switch to preview; `Cmd+double-click` in preview to jump back to edit; or select Side by Side from the toolbar to see both at once.
- **Bidirectional scroll sync** — in Side by Side mode, scrolling either pane keeps the other aligned to the same content.
- **Precise Find and Replace** — `Cmd+F` opens source or preview search with case-sensitive and whole-word options. Limit source replacements to a captured selection, see the replacement scope and count, and undo Replace All in one step. `Cmd+G` / `Shift+Cmd+G` continue the last search with the bar closed. See [matching and selection rules](Docs/MarkdownEditing.md).
- **Line numbers** — optionally show source line numbers in the editor, in the preview, or both. The editor numbers each line in a gutter beside the text (a soft-wrapped line is numbered once); the preview shows the starting source line of each rendered block and of each list item that spans several lines, so a number read while reading is the line to open in the editor. Click a number to select its line: in the editor gutter (Shift-click or drag to select several lines), or in the preview, which selects the line in the editor beside it in Side by Side and opens the editor on it from Preview. Toggle either scope from the toolbar or in Settings; numbers never appear in exported PDF, print, or HTML.
- **App settings** for language, default open mode (Edit / Side by Side / Preview), default outline visibility, line numbers (editor and preview), and the export profile (page size, orientation, margins, page numbers, headers/footers).
- **Markdown file type declaration** for `.md` and `.markdown` files when packaged.

See [Docs/MarkdownSupport.md](Docs/MarkdownSupport.md) for the tested Markdown/Typora support matrix.

The Format and Paragraph menus offer `Cmd+B` for bold, `Cmd+I` for italic, `Cmd+K` for links (using a clipboard URL when available), `Option+Cmd+1–6` for headings, `Cmd+0` for body text, `Option+Cmd+C` for code blocks, and `Option+Cmd+T` for tables. `Cmd+1/2/3` remain mode shortcuts. See [Markdown editing](Docs/MarkdownEditing.md) for behavior and regression tests.

## Install

Requires macOS 15 or later.

Download the latest `Markdown2.app` from [Releases](https://github.com/stutiredboy/md2/releases), then drag it to `/Applications`.

> [!NOTE]
> Apps downloaded from GitHub Releases are not signed or notarized by Apple. macOS Gatekeeper will block them with a "damaged" warning. Run the following command to remove the quarantine attribute:
>
> ```sh
> xattr -cr /Applications/Markdown2.app
> ```
>
> Then open **System Settings → Privacy & Security** and click **Open Anyway**, or simply double-click the app.

## Run from Source

```sh
swift run Markdown2
```

Open a file directly:

```sh
swift run Markdown2 path/to/file.md
```

Build a local macOS app bundle (creates `dist` only; no installation or file-association changes):

```sh
Scripts/package_app.sh
open dist/Markdown2.app
```

The default bundle uses `dev.codex.md2.development`, keeping preferences and recovered drafts separate from releases. `swift run` retains its own debug identity. Use `--release` for the distributed identity. Installation and default-handler changes are explicit:

```sh
# Install a development copy alongside the release
Scripts/package_app.sh --install '/Applications/Markdown2 Development.app'
# Explicitly replace the release installation and make it the default editor
Scripts/package_app.sh --release --install /Applications/Markdown2.app --set-default
```

`--set-default` requires `--install`; the destination's parent must exist. The legacy `MARKDOWN2_INSTALL_APP` environment variable no longer triggers installation. CI packages with `--release` and rejects installation arguments. Ad-hoc signing remains supported; these changes do not require a developer account or notarization.

Run local verification (default tests, isolated performance checks, workflow tests and development-bundle validation):

```sh
Scripts/functional_test.sh
# Also run native-window/WebKit tests; requires a usable desktop session and relevant Accessibility permissions
Scripts/functional_test.sh --gui
```

GUI skips are checked against the existing allowlist and are not counted as executed passes. The script no longer terminates the user's running application, rewrites app preferences or requires a different system default editor.

## Test

```sh
swift test
```

To time the inline renderer's scaling workloads in a release build, or to compare them with an older revision, see [Docs/Benchmarks/inline](Docs/Benchmarks/inline/README.md):

```sh
bash Scripts/benchmark_inline.sh
```

## License

Markdown2 is open source under the [MIT License](LICENSE).
