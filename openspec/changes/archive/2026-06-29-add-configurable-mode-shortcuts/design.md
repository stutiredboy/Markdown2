## Context

Markdown2 already has three presentation modes (`write`, `read`, `split`) and a single mode-switch path in `ContentView.requestMode(_:)` that preserves viewport anchors while moving between modes. The app also already stores user preferences in `AppSettings` and exposes them in `SettingsView`.

Mode entry/exit is currently uneven: Edit can be entered from Preview with Cmd+double-click, and Esc can leave Edit for Preview through the editor surface, but the three modes do not have direct keyboard commands and the bindings are not configurable.

The shortcut defaults should avoid macOS system-level and common app-level shortcuts. `Command-1`, `Command-2`, and `Command-3` are direct, discoverable, and not system-reserved; they also match the mental model of a three-segment mode control without colliding with the app's existing New, Open, Save, Close, Print, or Find commands.

## Goals / Non-Goals

**Goals:**

- Provide default direct shortcuts:
  - Edit: `Command-1`
  - Preview: `Command-2`
  - Side by Side: `Command-3`
- Store those shortcuts in configuration so the defaults can be changed per user.
- Route mode shortcut commands to the frontmost document and reuse existing mode-switch anchoring.
- Expose shortcut configuration in Settings with validation against duplicates and reserved/common shortcuts.
- Preserve Esc and Cmd+double-click behaviors.

**Non-Goals:**

- Replacing the existing toolbar segmented control.
- Adding a global system-wide hotkey outside Markdown2.
- Building a full macOS-style keyboard shortcuts editor for every app command.
- Changing default open/new document presentation mode preferences.

## Decisions

### Store mode shortcuts as a typed settings value

Add a small Codable settings model, for example `ModeShortcutConfiguration`, keyed by `EditorMode` and containing a key equivalent plus modifiers. `AppSettings` owns a published `modeShortcuts` value and persists it as JSON in `UserDefaults`.

Default configuration:

| Mode | Shortcut |
| --- | --- |
| Edit | `Command-1` |
| Preview | `Command-2` |
| Side by Side | `Command-3` |

Alternative considered: hard-code `.keyboardShortcut("1")`, `.keyboardShortcut("2")`, and `.keyboardShortcut("3")` directly in `MD2App.swift`. That would satisfy the initial defaults but would not meet the requirement that users can change the bindings later.

### Route through document command state, not direct view access

Add a mode command publisher to `DocumentStore`, similar to the existing `findCommand`. `MD2App.swift` menu commands set `currentDocumentStore?.modeCommand = ModeCommand(.write/.read/.split)`. `ContentView` observes the command and calls `requestMode(_:)`.

This keeps the command bridge consistent with the existing find flow and avoids exposing `ContentView.requestMode(_:)` outside the view. It also preserves the current anchor-capture behavior because all shortcut-triggered changes use the same path as the toolbar picker.

Alternative considered: store the current mode in `DocumentStore` and mutate it directly from app commands. That would make commands easy to call but would mix view-local scroll/anchor state into the model and risk bypassing the existing mode transition safeguards.

### Validate before applying customized shortcuts

The settings UI should reject or surface validation errors for:

- Duplicate shortcuts among Edit, Preview, and Side by Side.
- Existing Markdown2 command shortcuts such as `Command-N`, `Command-O`, `Command-S`, `Command-W`, `Command-P`, `Command-F`, `Command-G`, `Command-Shift-G`, and `Command-Option-F`.
- macOS/system-reserved or high-risk bindings such as `Command-Space`, `Command-Tab`, `Command-Backtick`, `Command-H`, `Command-M`, `Command-Q`, `Command-Option-Escape`, Mission Control/Spaces shortcuts, and bare Escape.
- Empty or malformed assignments.

If stored shortcut data cannot be decoded or fails validation at launch, the app should fall back to the default mode shortcut configuration rather than registering unsafe commands.

Alternative considered: allow any key equivalent and rely on SwiftUI/AppKit conflict behavior. That would make customization simpler but could silently shadow critical commands or create shortcuts that never fire because macOS consumes them first.

### Show configured shortcuts in app commands and Settings

Add mode commands to the menu, preferably in the View menu or a Mode submenu, with their configured keyboard shortcuts. Settings should display the three shortcuts with a compact recorder/control and a reset-to-default action for the mode shortcut group.

The first implementation can use a focused shortcut recorder backed by `NSEvent` key-equivalent capture, then serialize the normalized shortcut. If a native control is introduced later, it should still write the same settings model.

## Risks / Trade-offs

- [Risk] SwiftUI command menus may not refresh dynamic keyboard shortcuts immediately after settings edits. → Rebuild commands from `appDelegate.settings` and verify live updates; if needed, force the Settings change to publish through `AppSettings.objectWillChange` or require command model identity changes.
- [Risk] Capturing shortcuts from text fields can interfere with regular text input. → Use an explicit recorder control that only captures while active and commits/cancels clearly.
- [Risk] Some shortcuts are not globally reserved but are conventional in specific apps. → Block the app's own known shortcuts and the strongest macOS/system conflicts, but allow advanced users to choose app-specific alternatives that do not collide inside Markdown2.
- [Risk] Invalid legacy/defaults data can break command registration. → Validate decoded settings and fall back to `Command-1/2/3`.
- [Risk] Shortcut-triggered mode changes could regress scroll preservation. → Route through `requestMode(_:)` and add tests/manual QA for Edit→Preview, Preview→Edit, and entering/leaving Side by Side.

## Migration Plan

1. Add the shortcut settings model with defaults and validation.
2. Initialize `AppSettings.modeShortcuts` from `UserDefaults`, falling back to defaults when missing or invalid.
3. Add mode command routing through `DocumentStore` and `ContentView`.
4. Add menu commands using configured shortcuts.
5. Add Settings UI to edit/reset the three shortcuts.
6. Add tests for default values, persistence, validation, and command routing.

No stored-data migration is required for existing users because absence of the new key resolves to the default `Command-1/2/3` bindings. Rollback can ignore or remove the new defaults key; existing document mode preferences are unaffected.

## Open Questions

- Whether the visible menu label should use "Side by Side" or the shorter existing localized "Mode" submenu structure.
- Whether shortcut customization should ship as a minimal recorder in General settings or be separated into a future Keyboard Shortcuts settings section once more commands become customizable.
