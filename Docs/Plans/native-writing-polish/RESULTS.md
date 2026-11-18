# Native writing polish acceptance — 2026-11-18

The candidate is based on `306d3cab856fbc241d7c0c6a8bc6cb5d639379fe`.
The product-source diff SHA-256 is
`7702ab7685e3f74f5de23c3212fda2e811843d4dd78f8ab742750a1fb72c2e5a`.
Verification ran on Apple silicon with macOS 27.2.1, Xcode 27.2, and Swift 6.4.2.
The isolated optimised development bundle has a verified macOS 15.0 minimum
and passed strict ad-hoc signature verification. Its executable SHA-256 is
`fc59d010fe7cfe1105a33a0f4c141271a644127e59a19b844105c1c22a412a02`.

## Writing and regression coverage

Use the English recovery procedure and the Chinese handover note from the
[writing plan](PLAN.md). Eleven baseline native reading and corpus checks
passed before the new control was added. The candidate's regressions check:

- A native key edit or caret move centers the active wrapped row within the
  normal scroll bounds. A user can keep manually scrolling, and a key edit
  can reveal a caret left outside the viewport. Marked text, extended selection,
  programmatic location changes, and the toggle preserve their normal behavior.
- Write, Side by Side, and Preview preserve the UTF-16 source selection. In a
  same-width passive round trip, the restored scroll offset is within one
  point. Immediate preview scrolling follows the live page on return, with
  the same source selection. Hidden Find restores the match index and highlights.
  An explicit Find Next remains usable after the switch.
- English and Simplified Chinese expose the native menu checkmark and the
  compact toolbar's localized, live shortcut help. A narrow window retains
  native Find and Replace field identity, selection, value and focus when the
  setting toggles in each presentation mode.
- Turning the setting on yields byte-identical standalone HTML, matching PDF
  page count and extracted text, and byte-identical CRLF Markdown after Save.
  The toggle produces no dirty state or Undo action.

Independent source review found that an external reload could otherwise replay
an old UTF-16 offset and that a preview context replacement could outlive the
viewport record used to restore the source. The candidate invalidates both
records at the relevant boundaries. Deferred editor focus and scroll work
verifies ownership of the active native host.

The full suite caught an initial Preview-to-Edit regression. Limiting ordinary
viewport observation to a partial TextKit layout made the first styling chunk
scroll against a frame that was still too short. The result landed 22 source
lines above the target. The candidate retains complete layout for that native
observation. The extra report triggered by typewriter scrolling measures the
visible rectangle.
A document that opens in Preview initializes its first source caret at the
anchored line. The original styled viewport test also asserts that caret.

## System input

The separately identified candidate opened working copies of the English and
Chinese fixtures. Keyboard events went through the macOS WindowServer. In
English, the keyboard opened the Mode menu and toggled the checkmark while Find
retained its query. The Simplified Chinese app reopened with the localized
checked menu item. With the macOS Simplified Pinyin input method, entering
`nihao` kept the title clean and the caret row in place. Space committed
「你好」 and one Undo restored the clean source.

VoiceOver was active in a separately signed copy of the optimized candidate
before the final first-entry viewport correction.
At 816 points wide in both app languages, VO navigation placed the cursor on
the localized Mode menu item. VO+Space toggled the checkmark and returned to
the Find field with its query and insertion point intact. The evidence is
the visible VoiceOver cursor, the native menu state, and the focused field.
Speech captions and physical keyboard input were outside this observation.

## Local commands

```sh
bash Scripts/functional_test.sh
MD2_RUN_GUI_TESTS=1 swift test --disable-swift-testing > /tmp/md2-writing-gui.log 2>&1
python3 Scripts/check_test_skips.py /tmp/md2-writing-gui.log .github/gui-expected-skips.txt
```

The default lane passed 1,106 Swift Testing cases and 46 ungated XCTest cases.
The four isolated timing gates and 43 Python workflow tests passed. Packaging
used a separate development identifier and build-only mode.

The 17 focused cases passed on the final source, including the first source
caret and styled viewport, editor rehosting, Undo-sensitive editing, and HTML
and PDF isolation. During the initial full-lane attempt, macOS locked at
19:00:53 and the cross-process Accessibility calls reported unavailable or
misidentified windows. The in-process follow-up completed the remaining
in-process cases. After the desktop was unlocked, all 45 outstanding cases
passed on the same source from 19:32:32 to 19:34:32 local time.

| Cross-process suite | Passed after unlock |
| --- | ---: |
| Document links | 4 |
| Menu language and shortcuts | 5 |
| Recent documents and native input | 20 |
| Settings window | 16 |

The rerun exercised the real Simplified Pinyin composition test and restored
the original U.S. input source. It reported zero failures and zero skips.
Reconciliation by test ID across the three runs covered all 350 XCTest cases.
349 passed, and the optional user-supplied PDF export probe was the sole
allowlisted skip. The skip audit passed. The final source and development
package matched the recorded hashes.
