## Why

Markdown2 shows no line numbers on either surface. On a long working document
(release notes, runbooks, specs — hundreds to thousands of lines) there is no
way to see *where you are* in the source: the status bar reports only a total
line count, find tells you "3 of 17", and the preview hides source structure
entirely behind rendered HTML. Readers lose their place and cannot refer to a
location ("see line 214") in review comments or editor hand-off.

The two surfaces fail differently and both matter:

- **Editor:** the source is right there, but with soft wrapping and 30pt
  headings the eye has no fixed anchor; a scroll position carries no line
  information.
- **Preview:** every source line collapses into rendered blocks, so the
  connection between what is read and where it lives in the file is severed.
  A reader who spots a problem in a 900-line document has no idea which line to
  open.

Line numbers are a display preference, not document content: they must be
switchable, scoped per surface, and must never contaminate exported PDF, print,
or HTML.

One honest scope note up front: preview numbers are **block-start
annotations**. A paragraph, heading, or short table gets the number to open;
a block that spans hundreds of lines (a long code block, a 60-item list) gets
the number of its first line only — inside it, the anchor is the block, not
your row. Precise in-block location is the deferred click-to-jump follow-up
(see TODOS.md), not a promise this change makes.

## What Changes

- **Two independent display preferences**, persisted in `UserDefaults` and
  defaulting to **off** (today's behavior):
  - Show line numbers in the **editor**
  - Show line numbers in the **preview**
  Both SHALL be settable at the same time — enabling one SHALL NOT change or
  disable the other, and Side by Side honors each pane's own preference.
- **Editor gutter:** a line-number gutter to the left of the source text showing
  the 1-based source line of each logical line. Soft-wrapped lines are numbered
  once (a wrapped paragraph shows a single number at its first visual row).
  Numbers follow edits and scrolling.
- **Preview gutter:** a left margin showing, next to each rendered block, the
  1-based source line that block starts on — reusing the source-line metadata
  every rendered block already carries. Numbers align with the editor's, so a
  line read off the preview is the line to open in the editor.
- **Settings UI:** a "Line Numbers" group in Settings ▸ General with the two
  toggles, labeled in English and Simplified Chinese.
- **Quick toggle:** a toolbar control next to the outline button offering the
  same two scopes, so users can flip numbers on for the surface they are
  looking at without opening Settings. It writes the same preferences.
- **Export isolation:** line numbers SHALL NOT appear in exported PDF, printed
  output, or exported HTML, and SHALL NOT alter export layout.

Out of the box (no saved preference) both scopes are off, so existing users see
byte-identical behavior until they opt in.

## Capabilities

### New Capabilities
- `line-number-display`: How source line numbers are displayed and configured —
  the two independent editor/preview preferences, the editor gutter, the
  preview block gutter, their combined behavior in Side by Side, and the
  guarantee that numbers are display-only and never reach exports.

### Modified Capabilities
- `preview-layout`: gains one requirement — when preview line numbers are
  enabled, the number gutter reserves its own space so it never overlaps the
  content column, never introduces horizontal page scrolling (including on
  narrow windows), and leaves PDF export layout unchanged.

## Impact

- `Sources/MD2App/AppSettings.swift`: two new `@Published` preferences
  (`MD2.ShowsLineNumbersInEditor`, `MD2.ShowsLineNumbersInPreview`, both default
  `false`), plus new `L10nKey` cases for the labels in English and Simplified
  Chinese.
- `Sources/MD2App/MarkdownEditorView.swift`: line numbers drawn by
  `MarkdownSourceTextView.draw(_:)` inside the text view's existing 58pt left
  inset (per design Decision 2 — no `NSRulerView`: a ruler would consume
  clip-view width and re-wrap the document), plus a `showsLineNumbers` input
  and the explicit gutter-strip invalidation triggers.
- `Sources/MD2App/MarkdownPreviewView.swift`: a `showsLineNumbers` input and a
  preview-only gutter pass inside the existing injected user script (the same
  layer that already carries the front-matter toggle and find highlighting).
- `Sources/MD2App/ContentView.swift`: wire both preferences into the two panes
  and add the toolbar control next to the outline toggle.
- `Sources/MD2App/SettingsView.swift`: the Settings ▸ General group with the two
  toggles.
- `Sources/MD2Core/MarkdownRenderer.swift`: **expected to need no change** —
  `data-md2-source-line` is already emitted on every top-level block. If the
  preview gutter needs finer metadata than block granularity, that assumption is
  revisited in design.
- Tests: pure settings/defaults logic in the non-GUI suite; gutter rendering and
  the export-isolation guarantee in the `MD2_RUN_GUI_TESTS`-gated suite (WebKit
  and AppKit rulers need a window server).
- User-facing docs: `README.md` / `README.zh-CN.md` feature list, if they
  enumerate display preferences.
