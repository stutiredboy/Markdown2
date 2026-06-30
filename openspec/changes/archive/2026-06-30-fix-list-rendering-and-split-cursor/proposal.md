## Why

Nested list rendering currently loses visible child indentation for real-world Chinese monthly-report content, making parent and child bullets appear as peers. In Side by Side mode, typing can intermittently disturb the editor caret/viewport, likely because live preview rendering or scroll synchronization feeds back into the editing pane.

## What Changes

- Preserve nested ordered, unordered, mixed-kind, and task-list structure in rendered HTML and preview styling so child items are visibly indented.
- Add coverage using the reported monthly-report list pattern and adjacent ordered/unordered nesting variants.
- Prevent Side by Side live preview updates and sync scrolling from moving the editor caret or editor scroll while the user is actively typing.
- Add targeted tests or verification for typing in Side by Side mode and for the provided monthly-report document.

## Capabilities

### New Capabilities

### Modified Capabilities
- `list-rendering`: Nested ordered/unordered/task lists must render with structural nesting and visible indentation for child items.
- `split-view-editing`: Side by Side typing must keep editor focus, selection, caret, and viewport stable while preview rendering and scroll sync update.

## Impact

- Affected core renderer and preview styling paths in `Sources/MD2Core`.
- Affected Side by Side editor/preview coordination in `Sources/MD2App`.
- Adds or updates Swift tests under `Tests/MD2CoreTests`.
