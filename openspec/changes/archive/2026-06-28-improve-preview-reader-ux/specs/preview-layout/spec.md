## ADDED Requirements

### Requirement: Side by Side remains usable with the outline visible
When Side by Side mode and the outline are both visible, the app SHALL preserve usable editor and preview pane widths. The editor pane SHALL remain at least 360 pt wide and the preview pane SHALL remain at least 420 pt wide in Side by Side mode. The layout SHALL avoid placing the outline, editor, and preview into a window width that causes the editor or preview pane to collapse below its minimum usable width.

#### Scenario: Default window enters Side by Side with outline
- **WHEN** a document window is at the app's default size
- **AND** the outline is visible
- **AND** the user switches to Side by Side mode
- **THEN** the editor and preview panes both remain at or above their minimum usable widths
- **AND** neither pane overlaps the outline or status bar

#### Scenario: Constrained window adapts layout
- **WHEN** the window is too narrow to show the outline, editor pane, and preview pane at their minimum usable widths
- **AND** the user switches to Side by Side mode
- **THEN** the app adapts by widening the window, temporarily collapsing the outline, or otherwise preserving both pane minimum widths
- **AND** the user can still restore the outline explicitly

#### Scenario: Window minimum accounts for visible outline
- **WHEN** Side by Side mode and the 230 pt outline are both visible
- **THEN** the document window minimum width accounts for the outline, split divider, editor minimum width, and preview minimum width
- **AND** the app does not silently change the user's explicit outline visibility preference

#### Scenario: Split divider preserves minimum panes
- **WHEN** the user drags the Side by Side divider
- **THEN** the editor pane cannot be resized below its minimum usable width
- **AND** the preview pane cannot be resized below its minimum usable width

### Requirement: Layout adaptation is reversible and predictable
Any automatic layout adaptation triggered by Side by Side with the outline visible SHALL be reversible and SHALL not permanently change the user's outline preference unless the user explicitly changes that preference.

#### Scenario: Leaving Side by Side restores previous outline context
- **WHEN** the app temporarily hides or collapses the outline to preserve Side by Side pane widths
- **AND** the user leaves Side by Side mode
- **THEN** the outline visibility returns to the user's prior explicit state when there is enough space

#### Scenario: User explicitly hides outline
- **WHEN** the user hides the outline from the toolbar or menu
- **THEN** the app treats the outline as explicitly hidden
- **AND** later Side by Side layout adaptation does not re-show it without user action

#### Scenario: Window resize keeps panes readable
- **WHEN** the user resizes a Side by Side document window while the outline is visible
- **THEN** the layout preserves the editor and preview minimum usable widths
- **AND** the app applies the same adaptation rules consistently as the available width changes
