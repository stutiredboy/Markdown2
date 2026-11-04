## Context

The document toolbar is a SwiftUI `.toolbar` bridged onto an AppKit document window. On `main` it had Outline and Line Numbers in the navigation group, and Open, Save, the metadata button (only outside Write mode, only with front matter) and the mode picker in the primary group, in that order. Each button set `.labelStyle(.titleAndIcon)`, and the picker had `.frame(width: 280)`.

Measured on macOS 27.2 by reading `window.toolbar` at each width:

| Item | With text | Icon only |
|---|---|---|
| Outline | 123.5 pt | not used |
| Line Numbers | 131 pt | 45 pt |
| Metadata | 136.5 pt | 36 pt |
| Mode picker | 289.5 pt in English | 115.5 pt |
| Open | 92.5 pt | not used |
| Save | 74 pt | not used |

The navigation group starts at 96.5 pt, after the traffic lights. The window title then keeps about 168 pt: items overflow before the title shrinks below that, however long the file name is.

Three findings shaped the change:

- **`NSToolbar` overflows strictly from the trailing end.** With the picker first in the primary group, the order was metadata, Save, Open, picker. With the picker last, it went first.
- **The picker never showed text.** A toolbar's default label style is icon-only, and only the buttons overrode it. `improve-preview-reader-ux` removed the picker's explicit `.labelStyle(.iconOnly)` and widened it from 132 pt to 280 pt to make room for text that never appeared. The three icons sat in the middle of the frame, with about 165 pt of it unused.
- **`accessibilityLabel` and `help` on a segment's label never reach the segment.** `NSSegmentedControl` reported no tooltips, and each icon segment's accessibility label was the symbol's own description in the system language: `拆分为二乘一的矩形` for Side by Side, on a machine set to Chinese with the app in English.

## Decisions

### The picker's position gives it priority

The picker now sits left of Open and Save, so AppKit's own overflow reaches it after them. This holds whatever the metrics are, so the guarantee does not depend on the widths in the next decision being right on every macOS. If they are wrong on some release, Save overflows, not the mode control.

*Alternatives considered:*
- **`.principal` placement.** It overflowed exactly as the picker first in the primary group did, so it adds no priority. A centered picker also has more room to its right than it needs, and less to its left, where the title is.
- **`NSToolbarItem.visibilityPriority`.** This is AppKit's direct answer, and it would keep the picker at the far right. SwiftUI does not expose it. The items SwiftUI creates have generated identifiers, so the app would have to find its item by label and reapply the priority whenever the toolbar changes, which depends on bridging details no API promises.
- **Moving the picker into the content area.** The spec and the audit both place it in the toolbar.

### The metadata button goes on the group's leading end

The primary group is anchored to the trailing edge, and the metadata button appears when the mode leaves Write. Anywhere right of the picker, it would push the picker left by its own width, about one segment, in the moment after the user clicked that picker. A second click would land on a different mode. On the leading end, nothing to its right moves. Before this change the picker was at the far right, so it never moved, and this keeps that property. `testSwitchingModeDoesNotMoveThePicker` fails if the button goes back to the trailing end.

### Width-driven densities, from the width alone

`DocumentToolbarDensity` has three cases, and the window width alone picks one:

| Density | From | Outline, Open, Save | Line Numbers, metadata | Mode picker |
|---|---|---|---|---|
| `full` | 1160 pt | text | text | text |
| `reduced` | 960 pt | text | icon | text |
| `compact` | below 960 pt | text | icon | icons |

The widths are measured for English, the wider language, with the metadata button showing. They need about 1145 pt and 958 pt. `compact` needs about 784 pt.

A single rule keeps the toolbar predictable. Because neither the language, the document nor the mode feeds into it, a mode switch cannot change what the labels show, and so cannot change the picker's width. The cost is that zh-Hans, and documents with no metadata button, lose the Line Numbers text at widths where it would have fit.

`onGeometryChange` turns the width into a density before it reaches the view's state, and the action only runs when the density changes. Resizing a window therefore does not re-evaluate `ContentView.body` on every frame, only at the two widths where the labels change.

*Alternatives considered:*
- **Measuring the label text.** The result would follow the language, but string widths are only part of the budget. The item padding and the title's reservation are not available to measure, and they differ between macOS releases, so this would be more code for an estimate.
- **Reacting to overflow.** Watching `visibleItems` and collapsing when something is hidden would use the real layout, but collapsing a label changes what fits, so the toolbar could oscillate at a boundary. It would need hysteresis to settle.
- **`ViewThatFits`.** Not tried. It chooses by the width it is offered, and each toolbar item here sizes to its own content, so there is no shared width for it to compare against.

### Text and icons are separate forms, chosen with built-in styles

The toolbar honors only the built-in label styles. A custom `LabelStyle` that branches on the density rendered Line Numbers as an icon at every width, and left the picker with both a title and an image. `CollapsibleToolbarLabel` is a `ViewModifier` that applies one of two built-in styles instead.

The picker's text form uses `.titleOnly` rather than `.titleAndIcon`. They render alike on macOS 27, but `.titleOnly` says what the width budget assumes, so another release cannot add icons to the segments.

### The segment's image carries the mode's name

`modeSegment` builds its icon from `NSImage(systemSymbolName:accessibilityDescription:)`, because the image's description is what the segment exposes. The form with a plain `Image(systemName:)` and `.accessibilityLabel` on the image or on the label does not reach it. Help stays on the control, as `.help`, and its `writeReadOrSplit` sentence names the three modes in order. On macOS 27 `.help` lands on the toolbar item's `toolTip`. On macOS 15 `toolTip` reads `nil`, so the test does not rely on it: see Verification.

### The spec's default-width rule stands

The task allowed for amending this rule, on the expectation that it might not fit alongside keeping the picker. It does fit. At 980 pt the English worst case needs about 958 pt, so the delta only adds requirements. The mode control also meets the rule for the first time, since it now shows text there.

## Verification

- **The old toolbar fails all 7 GUI tests.** The widths the matrix test finds the control hidden at match the audit's measurements exactly: through 1100 pt in English with front matter, through 980 pt in English without, through 980 pt in zh-Hans with, and at 800 pt in zh-Hans without. So the off-screen harness reproduces the real failure.
- **With the fix, all 7 pass:** in the whole GUI lane and in 3 further runs in a row.
- **Mutations:**
  - Putting the metadata button back on the trailing end fails only `testSwitchingModeDoesNotMoveThePicker`.
  - Using a plain `Image(systemName:)` in the segments fails only `testCollapsedControlsKeepLocalizedNamesAndHelp`.
  - Removing `.help` from Line Numbers fails the same test, in both languages.
- **macOS 15, CI's first run:** 6 of the 7 GUI tests passed, including the whole width matrix, so the mode control stays in the toolbar there too. The seventh failed only on reading `NSToolbarItem.toolTip`, which was `nil` for every control it checked. `testCollapsedControlsKeepLocalizedNamesAndHelp` now reads the item, its views and their accessibility elements, and uses Open as a control, because Open never collapses and has no `CollapsibleToolbarLabel`. If Open's help reads back and a collapsed control's does not, the test fails. If Open's does not read back either, that macOS gives the test nothing to compare, so it checks the names only and says so in the log.
- **The density boundaries,** in both languages, in Side by Side and Read, with front matter: nothing is hidden at 959, 960, 1159 or 1160 pt, so each density fits from the width that selects it. At 780 pt, Read in English hides Save only, and at 784 pt nothing is hidden.
- **Suites:** the three non-GUI CI steps pass. The whole GUI lane passes with 147 tests, 0 failures and 2 skips, both in `.github/gui-expected-skips.txt`, and `Scripts/check_test_skips.py` accepts it.
- **Rendering:** checked in windows captured through the window server, in English and zh-Hans, in light and dark. Rendering the window's views in process with `cacheDisplay` is not evidence for this control: it drew the selected segment blank and the picker's glass as an empty circle, and neither appears in a composited window.
- **Not verified locally:**
  - macOS 15. Only CI's `gui-tests` job covers it. If help cannot be read back there, the collapsed controls' tooltips on that release are untested, and rest on `.help` being applied to them as it is to Open.
  - The selected segment in an active window. The captures come from a test process that is not frontmost, so they show the inactive palette.
  - VoiceOver's speech. The tests read the accessibility labels it would use, not its output.

## Risks / Trade-offs

- **macOS 15 is only checked by CI.** Its toolbar metrics differ from macOS 27, and the widths above were measured on 27. `DocumentToolbarGUITests` runs on CI's macOS 15, and the picker's position protects the mode control if the metrics are worse.
- **The default width has about 20 pt of slack** in English with the metadata button. A longer label there would push Save into the overflow menu at 980 pt, and `testDefaultWidthLabelsPrimaryActions` would fail.
- **Save overflows between 780 and 784 pt** in English, in Read, with front matter. The window's minimum in Read is 780 pt, and `compact` needs about 784 pt. The mode control stays, and Save remains on ⌘S and the File menu. Dropping Outline's text in `compact` would close this, at the cost of that label at every width from 780 to 960 pt, which is a worse trade for four points.
- **The picker changes place and form.** It moves left of Open and Save, and shows text where it showed icons, so existing users will see a different toolbar. The text is what the spec asked for, and the place is what gives it priority.
- **A new language needs measuring.** The widths assume English is the widest. Anything wider would overflow earlier, Save first.
