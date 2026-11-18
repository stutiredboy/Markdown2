# Native writing polish

## Writing tasks and choice

| Task | What the writer needs | Decision |
| --- | --- | --- |
| Copy-edit `chinese-long-form.md` at the bottom of a narrow window. Add a sentence in the paragraph about the missing hex wrench and move through its soft-wrapped rows. | Keep some preceding and following text in view as the caret moves. | Offer typewriter scrolling. Clamp to the normal viewport limits so short notes and the ends of long notes remain readable. |
| Edit the recovery procedure in `technical-note.md`, compare the rendered list and code in Side by Side, and proofread in Preview before resuming the edit. | Find the key for each mode and return to the source selection and working position. | Use the existing mode picker's help and keep the actual shortcuts in the Mode menu. Keep the toolbar layout and native find fields. |
| Repeat either task with the outline hidden. | Use the available writing width without losing save or conflict feedback. | Edit and the existing outline control already meet this need. Keep the document chrome and defer a separate focus mode. |

The tasks use the [real-document corpus](../../../Tests/MD2CoreTests/Corpus/README.md).
The baseline native reading tests and the two corpus cases ran before the
new control was added.

## Behavior

- **Mode → Typewriter Scrolling** is an app preference, initially off.
  It applies to the source editor in Edit and Side by Side. It takes effect on
  the next edit or caret movement from the keyboard, and on committing text
  through the input method. Selection ranges, mouse selection, manual scroll,
  marked composition, and find or outline reveals have their normal behavior.
- A mode switch uses the same document-owned native editor and Undo history.
  Source viewport restoration preserves an existing caret or selection. When
  Preview is the document's initial mode, the first edit starts at the reading
  position. A passive visit
  to Preview preserves the source's wrapped row and its local offset. If the
  reader moves, the return follows the preview's source anchor. A source edit
  invalidates any saved character offset.
- Toggling the preference leaves the current native responder and the contents
  of its find and replacement fields intact. The ordinary mode commands retain
  the existing Find-bar dismissal rules and shared query. A restored query can
  highlight matches without revealing one until the user searches or navigates.
- The preference lives in the native source editor. Saving, live preview, HTML,
  and PDF use the same source and render settings in either setting.

## Acceptance gates

1. Exercise key input, movement across wrapped rows, short and long documents,
   both viewport limits, marked input and commit. Assert the resulting caret
   geometry and text, plus one native Undo. Check toggle, extended selection,
   Find, and manual scroll without triggering centering.
2. At the narrow toolbar width in English and Simplified Chinese, verify the
   mode labels, live custom shortcut help, checked menu state, and native focus.
   Use an active query or replacement field and preserve its selection.
3. Use Write → Split → Read → Write with a UTF-16 source selection and a stored
   Find query. Check the passive viewport return and separately prove that real
   preview navigation still wins. Keep explicit Find navigation working.
4. Check that the same document can be saved byte for byte and that both HTML
   and PDF keep the same content with the preference on and off.
5. Run the full default and GUI lanes with their performance checks and skip
   checks. Check an isolated package and get a non-author review of the final
   changes. Record system Pinyin, VoiceOver, and physical keyboard evidence
   separately from accessibility-tree assertions.
