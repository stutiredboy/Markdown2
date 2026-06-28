## ADDED Requirements

### Requirement: Short documents stay anchored at the top across a mode switch
The system SHALL keep a document that fits entirely within the viewport (its
content height is less than or equal to the visible height) pinned to the top
when switching between Read (preview) and Write (editor) modes. The system SHALL
NOT issue any scroll that pushes a fits-on-screen document out of view, so the
top of the document — including its first heading — remains visible after the
switch.

#### Scenario: Switch a short document from preview to editor
- **WHEN** a document that does not fill a page is shown in preview mode and the
  user switches to editor mode
- **THEN** the editor shows the document from its top, with the first heading
  visible and no manual scrolling required

#### Scenario: Content that fits produces no scroll offset
- **WHEN** the post-switch scroll offset is computed for a destination whose
  content height is less than or equal to the viewport height
- **THEN** the resulting scroll offset is 0 (the top)

### Requirement: Long documents scroll to the anchored position
The system SHALL scroll the destination to the captured anchor (the section
heading, or the proportional fallback) when its content is taller than the
viewport, clamping the offset so it never exceeds `contentHeight -
viewportHeight` and is never negative.

#### Scenario: Switch a long document from preview to editor
- **WHEN** a multi-page document is scrolled to a mid-document section in
  preview mode and the user switches to editor mode
- **THEN** the editor is scrolled so the same section is at the top, within the
  document's scrollable range

#### Scenario: Anchor beyond the bottom is clamped
- **WHEN** the captured anchor resolves to a target below the last scrollable
  position
- **THEN** the destination scrolls to the maximum offset
  (`contentHeight - viewportHeight`) rather than past the end
