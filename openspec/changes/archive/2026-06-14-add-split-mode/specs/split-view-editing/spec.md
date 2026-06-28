## ADDED Requirements

### Requirement: Side by Side shows the editor and preview together
The app SHALL provide a presentation mode named "Side by Side" (internal
identifier `split`) that displays the editable source and the rendered preview
simultaneously in one document window: the editor in a left pane and the live
preview in a right pane, separated by a vertical divider. Both panes SHALL be
visible and usable at the same time without any mode toggle. The outline sidebar
and status bar SHALL remain available exactly as in the single-pane modes.

#### Scenario: Entering Side by Side shows both panes
- **WHEN** the user selects Side by Side mode for a document
- **THEN** the window shows the Markdown editor on the left and the rendered
  preview on the right at the same time
- **AND** the outline sidebar (when enabled) and the status bar remain visible

#### Scenario: The split divider is adjustable
- **WHEN** the user drags the divider between the editor and preview panes
- **THEN** the relative widths of the two panes change accordingly
- **AND** neither pane collapses below a usable minimum width

#### Scenario: Editor is interactive in Side by Side
- **WHEN** the document is shown in Side by Side mode
- **THEN** the user can type, select, and edit text in the left pane just as in
  Edit mode

### Requirement: The preview re-renders live as the user edits
In Side by Side mode the right preview pane SHALL reflect edits made in the left
editor pane, re-rendering from the same render pipeline used by single-pane
Preview. The preview SHALL preserve its current scroll position across these
re-renders so that ongoing typing does not reset the preview to the top or cause
visible flashing of the whole document.

#### Scenario: Typing updates the preview
- **WHEN** the user types Markdown in the left editor pane
- **THEN** the right preview pane updates to show the rendered result of the new
  text

#### Scenario: Live re-render preserves preview scroll position
- **WHEN** the preview is scrolled away from the top and the user edits text
  whose rendered output is above the current preview viewport
- **THEN** the preview re-renders without jumping back to the top of the document
- **AND** the content the user was viewing remains in view

### Requirement: Scrolling keeps the two panes aligned
In Side by Side mode the editor and preview panes SHALL stay vertically aligned:
scrolling the editor SHALL move the preview to the corresponding rendered
content, and scrolling the preview SHALL move the editor to the corresponding
source content. Alignment SHALL use the same source-line / block anchoring model
as mode-switch scrolling, preferring a block/source-line anchor and falling back
to heading or proportional position when block metadata cannot be resolved.

#### Scenario: Scrolling the editor follows in the preview
- **WHEN** the user scrolls the editor pane so a particular source block is near
  the top of the editor viewport
- **THEN** the preview pane scrolls so the rendered output of that block is near
  the top of the preview viewport

#### Scenario: Scrolling the preview follows in the editor
- **WHEN** the user scrolls the preview pane so a particular rendered block is
  near the top of the preview viewport
- **THEN** the editor pane scrolls so the source lines for that block are near
  the top of the editor viewport

#### Scenario: Synchronized scrolling does not oscillate
- **WHEN** one pane is programmatically scrolled to follow the other
- **THEN** the followed pane SHALL NOT treat that programmatic scroll as a fresh
  user scroll that drives the originating pane back
- **AND** the two panes settle at the aligned position without visible jitter or
  feedback oscillation

### Requirement: Entering and leaving Side by Side preserves the reading position
When a document enters Side by Side mode the preview pane SHALL be aligned to the
position the user was at in the surface they came from, and the editor pane SHALL
keep that position. When a document leaves Side by Side mode for a single-pane
mode, the destination single-pane surface SHALL adopt the position of the
corresponding pane (the editor pane's position when entering Edit, the preview
pane's position when entering Preview).

#### Scenario: Switching Edit to Side by Side keeps the editor position
- **WHEN** the editor is scrolled to a position in Edit mode and the user
  switches to Side by Side
- **THEN** the editor pane stays at that position
- **AND** the preview pane is aligned to the same source content

#### Scenario: Switching Side by Side to Preview keeps the preview position
- **WHEN** the user is in Side by Side mode with the preview pane scrolled to a
  position and switches to Preview mode
- **THEN** the single-pane preview shows that same position

### Requirement: Per-pane features work in Side by Side
In Side by Side mode the editor and preview SHALL retain the per-surface
behaviors they have in single-pane modes. Find/Replace SHALL operate on the pane
that currently
has focus. Selecting an outline entry SHALL navigate both panes to that heading.
Clicking a task-list checkbox in the preview SHALL toggle the corresponding
source line and SHALL leave both panes at their current positions.

#### Scenario: Find operates on the focused pane
- **WHEN** the editor pane has focus and the user invokes Find
- **THEN** the find bar searches the editor source
- **WHEN** the preview pane has focus and the user invokes Find
- **THEN** the find bar searches the rendered preview

#### Scenario: Outline jump moves both panes
- **WHEN** the user selects a heading in the outline while in Side by Side mode
- **THEN** both the editor pane and the preview pane scroll to that heading

#### Scenario: Toggling a task checkbox keeps both panes in place
- **WHEN** the user clicks a task-list checkbox in the preview pane
- **THEN** the source line's task marker is updated and the editor reflects it
- **AND** both panes remain at their current scroll positions rather than
  jumping to the top

### Requirement: Side by Side is selectable from the toolbar
The document toolbar mode control SHALL offer Side by Side as a third option
alongside Edit and Preview, each represented by a distinct icon, and its
accessibility/help text SHALL be localized in English and Simplified Chinese.
Selecting it SHALL switch the active document to Side by Side mode.

#### Scenario: Selecting Side by Side from the toolbar
- **WHEN** the user picks the Side by Side segment in the toolbar mode control
- **THEN** the document switches to Side by Side mode
- **AND** the control reflects Side by Side as the active selection
