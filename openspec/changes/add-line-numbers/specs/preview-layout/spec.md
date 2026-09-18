## ADDED Requirements

### Requirement: The preview line-number gutter does not disturb the content column
When preview line numbers are enabled, the number gutter SHALL occupy its own reserved space so that numbers never overlap or obscure document text, and the content column SHALL NOT be covered by the gutter. Enabling the gutter SHALL NOT introduce horizontal scrolling of the page, including on windows narrower than the column's maximum width. The gutter SHALL remain legible in both light and dark appearance. When preview line numbers are disabled, the content column SHALL be laid out exactly as it is today.

#### Scenario: Numbers never overlap content
- **WHEN** preview line numbers are enabled
- **THEN** every number sits in the reserved gutter beside the content column
- **AND** no number overlaps or obscures document text

#### Scenario: Narrow window keeps fitting
- **WHEN** preview line numbers are enabled in a window narrower than the column's maximum width
- **THEN** the content column still shrinks to fit the window
- **AND** the page does not scroll horizontally

#### Scenario: Wide window keeps the column centered and capped
- **WHEN** preview line numbers are enabled in a window wider than the column's maximum width
- **THEN** the content column does not exceed its maximum width
- **AND** the remaining space still appears as balanced left and right margins

#### Scenario: Layout is unchanged when the gutter is disabled
- **WHEN** preview line numbers are disabled
- **THEN** the preview content column is laid out exactly as it was before the feature existed

#### Scenario: Side by Side preview pane reserves the gutter too
- **WHEN** a document is shown in Side by Side with preview line numbers enabled
- **THEN** the preview pane reserves the gutter within its own width
- **AND** the preview pane still respects its minimum usable width
