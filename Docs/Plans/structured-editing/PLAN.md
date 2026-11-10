# Structured source editing: tables and explicit paste

Status: implementation in isolated packages; acceptance pending.
Baseline: `a95388427ec6dbd4f6ea4a4f542472557eb73ac7` (PR #56 merged).

## Priority and outcome

| Package | Priority | Deliverable | Acceptance outcome |
| --- | --- | --- | --- |
| T: table editing | First | Tab/Shift-Tab cell navigation, append a row at the last cell, six explicit row/column commands. | Edit a supported source table without losing existing cell text, alignment, adjacent source or line endings. Native one-step Undo/Redo; navigation does not dirty the document. |
| P: explicit paste | Second | Paste as Plain Text, Paste as Markdown, Paste as Table (TSV). | Preserve ordinary Cmd-V behavior. Explicit conversion produces predictable Markdown or a clearly reported whole-input fallback; clipboard capture/conversion does not load resources. Native focus, stale-request and undo rules hold. |

T and P can implement independently after their contracts are frozen. Table
editing has acceptance priority. The existing renderer is not changed in this
batch, and neither package depends on the other's new parser or API.

## T: table contract

- Operate on top-level rectangular pipe tables with one header, an adjacent
  valid delimiter row, and zero or more body rows. All rows have the same number
  of columns. Support consistent zero-to-three-space indentation, optional
  outer pipes, escaped pipes and the supported single-backtick code-span subset.
- A single caret or selection wholly within one content cell is required. Tab
  and Shift-Tab select adjacent content, skipping the delimiter row. Navigation
  does not change text, undo or dirty state. Shift-Tab at the first header cell
  is a consumed no-op. Tab at the final cell appends one empty body row and
  selects its first cell, including header-only tables.
- Format > Table Operations supplies Insert Row Above/Below, Delete Row,
  Insert Column Before/After, Delete Column. Preserve the existing table-template
  command and shortcut. The header only permits inserting a body row below it;
  header/delimiter deletion is prohibited. Keep at least one column. Removing
  the last body row leaves a valid header/delimiter table.
- Preserve unmodified cell Markdown, padding, alignment markers and surrounding
  text verbatim. New cells use ordinary padding; new delimiter cells use `---`.
  Add only necessary outer pipes for new empty rows, edge columns or one-column
  results when otherwise the renderer would consume a separator as an outer pipe.
  Structural changes use one native replacement/undo step. Select the new cell
  after insertion or the nearest remaining cell after deletion.
- Preserve mixed source line endings outside edits. New rows inherit the local
  LF/CRLF/CR style; an EOF without a newline remains without a trailing newline.
  Validate UTF-16 ranges and retain Chinese, emoji and combining text.
- Reject ambiguous or unsupported structure rather than repair it: nested
  list/quote containers, code/HTML blocks, ragged rows, cross-cell/multiple
  selections, delimiter-row positions, unclosed or multi-backtick spans, and
  trailing nonstructural pipe cases where renderer interpretation differs.
  Explicit commands explain refusal. Unsupported Tab positions keep existing
  editor/list behavior. Bound scanning and transformation work: at most 500,000
  UTF-16 units and 20,000 physical source lines; a table and replacement each
  at most 100,000 UTF-16 units, 1,000 physical rows, 128 columns and 20,000
  cells, counting header and delimiter. Recheck limits after structural growth.
  Menu validation must not repeatedly scan the source.
- Read's first formatting action only reveals source. Find, filename and
  Settings fields must never cause edits to a hidden source selection. Marked
  text and pending reveal suppress commands without delayed replay.

## P: paste contract

- **Paste as Plain Text** uses the standard Option-Shift-Command-V shortcut.
  In source, insert the captured plain string exactly: no link synthesis,
  delimiter pairing, rich conversion or image handling. Native text fields
  retain their standard responder behavior. No plain representation means no
  source insertion.
- **Paste as Markdown** is an explicit Edit action without a default shortcut.
  Prefer HTML, then strict RTF, then plain string. HTML supports semantic
  paragraphs/breaks, headings, emphasis, safe links, lists, quotes and code.
  Recognize clipboard wrappers; CSS presentation is not preserved. RTF support
  is limited to literal/Unicode text, paragraphs and bold/italic. Unsupported
  RTF fields, list styles, images, objects and encodings are not interpreted.
- Use bounded pure text parsers. Do not use WebKit, system attributed-string
  HTML/RTF importers, external entity expansion, subprocesses, file or network
  reads. Never import rich-text images or emit resource-bearing HTML. Escape
  literal Markdown syntax; validate decoded links against the existing safe
  HTTP(S)/mailto policy. Active/resource content and malformed input are not
  partially converted.
- Unsupported or malformed rich input may fall back to its complete captured
  plain representation, escaped as literal Markdown prose with a localized
  notice that formatting was not retained. Literal fallback cannot activate
  image/raw-HTML/link syntax, including bare URLs and entity-like text. Capturing
  the entire plain representation does not prove it is equivalent to the rich
  representation; do not call this lossless rich conversion. Without a plain
  representation, leave the source unchanged and explain why. Never truncate.
  Any budget overflow, deadline, stale state or cancellation rejects the whole
  action without fallback or insertion.
- No-resource-loading claims apply to capture/conversion/menu validation, not
  the application's general preview policy. Explicit Plain Text and plain-only
  Markdown retain existing source semantics and may contain resource references;
  a consistent preview/export resource policy remains a separate batch.
- **Paste as Table** consumes TSV plain text. Its first row is the header;
  pad ragged rows to the widest row, preserving empty cells. Support quoted
  fields, doubled quotes and embedded tabs/newlines. A quote can open only at
  field start; malformed quoted records reject the entire operation. One final
  record terminator does not add an extra row. Explicit one-column input is valid.
- Serialize literal cell content so pipes, backticks, backslashes, entity-looking
  strings and HTML/Markdown-like text cannot change the table structure. Cell
  newlines become `<br>`, embedded tabs `&#9;`, edge ASCII spaces `&#32;`.
  Do not replace spaces with NBSP. HTML layout may collapse ordinary spaces;
  source/DOM text retains them. Verify output with the actual renderer.
- Insert generated tables as standalone blocks separated from surrounding
  nonempty source, using local line endings. Surrounding source remains intact.
- Initial limits: 1 MiB rich input, 2 MiB plain/TSV input and generated output,
  20,000 rich tokens, depth 64. TSV has at most 999 input rows, 128 columns,
  20,000 cells after rectangular padding and the generated delimiter row
  ((input rows + 1) times widest column count); generated table output also
  cannot exceed 100,000 UTF-16 units, aligning with T's table limits. Rich Data
  budgets count original bytes; other String and generated-output byte budgets
  count UTF-8 bytes, not grapheme counts. Conversion runs off-main with cooperative cancellation and a one-second
  deadline. Synchronous OS clipboard provision is outside that deadline.
- Capture clipboard value data consistently using changeCount, never promised
  files/URLs/RTFD/image objects. Capture source identity, exact UTF-16 bytes,
  selection, host/window and request generation at invocation; before adoption
  require the same editable focused source, no marked text, and the latest
  request. Source/selection/focus/mode/host changes cancel insertion.
- Apply once via native insertion, separate from adjacent typing's undo group.
  Delegate rejection must not move selection. Document-owned undo, dirty state,
  autosave and invalidation of frozen find scope remain intact.

## Workflow and verification

Each package has a separate branch/worktree and SPEC/HANDOFF with commands and
results. Shared menu/localization/editor files have explicit hunk ownership:
T owns Format/table integration; P owns Edit/paste integration. The coordinator
integrates only non-author-reviewed commits, sequentially. Findings return to
their author and are independently rechecked before acceptance.

GUI, native window/menu and clipboard tests hold one exclusive lease. Performance
and heartbeat tests run in isolation. Tests use private pasteboards where
possible; any real shared state is restored. No broadened skip list, weakened
assertions, blanket retries or hidden failures are acceptable.

Required gates:

1. Targeted positive and adversarial regressions, including rendering agreement,
   literal content/line endings, malformed syntax, budgets, stale operations,
   marked text, focus, native undo and menu state across window changes.
2. Independent review/probes for both packages. Resource safety requires checking
   the production conversion path, not merely a mocked network client or a
   disconnected machine.
3. Integrated default Swift tests, isolated rendering performance/heartbeat,
   Python workflow/package tests, complete native GUI and expected-skip audit.
4. SDK15 compile, safe development packaging and final installed-app/default
   association comparisons. English/Chinese labels and accessible command names
   are verified. Native automated interaction is labeled as such; physical
   keyboard/mouse, VoiceOver or Pinyin claims require those actual observations.
5. Final-source macOS15 CI, all four jobs and the same artifact through both
   consumers, independently verified. Preserve failed-run evidence.

Original installed app, default Markdown handlers and original repository
tracked files remain unchanged. PR creation and ready-for-review are allowed;
merge, tag, release and installation are not part of this task. Developer ID
signing and notarization remain deferred by the user's instruction.

## Later batches

A consistent remote-resource policy across preview/PDF/print/HTML, browseable
version history, folder navigation and progressive live editing remain separate
batches. Complex nested table editing and a full rich-document converter are not
implied by this bounded source-editing contract.
