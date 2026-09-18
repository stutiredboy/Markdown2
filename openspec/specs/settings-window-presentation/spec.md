# settings-window-presentation Specification

## Purpose
Define when the Settings window may appear: the app never presents it as part of launching or activating — direct launch, opening a document from the Finder or `open` (which launches the app), or re-activation — while the app menu's Settings… (⌘,) still opens it on request and restores its saved frame. Also records the macOS 15 minimum system version the launch-presentation opt-out requires, and why the Settings scene cannot simply be left undeclared (document windows are AppKit-managed, so it is the app's only SwiftUI scene).
## Requirements
### Requirement: Launching the app does not present the Settings window

Launching or activating the app SHALL NOT present an *unsolicited* Settings window — one that appears without the user asking for it — for every launch path: a direct launch with no file, a launch that opens one or more documents (file argument, Finder, or `open`), and activation of an already-running app. Existing launch/reopen behavior is explicitly preserved and is not a violation: a blank document opened at launch when the "open a blank document on launch" preference is enabled; a new document created by Dock reopening when no document window exists; and a Settings window the user opened earlier remaining open across activation. At the end of launch the visible windows SHALL be exactly those the app's existing launch, reopen, and open-document handling presents (none, when no document was requested and the blank-document preference is disabled).

The app's only SwiftUI scene is `Settings` (document windows are AppKit-managed), and SwiftUI presents the app's only scene at launch when the executable is linked below the macOS 15 SDK — so this requirement is met by opting the scene out of launch presentation, not by leaving the scene undeclared: the Settings scene and its app-menu command MUST continue to exist.

#### Scenario: Direct launch presents no window

- **WHEN** the app is launched directly with no file argument and the "open a blank document on launch" preference is disabled
- **THEN** no Settings window is created or made visible
- **AND** no other window is presented either; the app activates with its menu bar available

#### Scenario: Opening a document presents only the document

- **WHEN** the app is launched with a Markdown file argument, or a file is opened via Finder (which launches the app, or opens a window in the running instance)
- **THEN** exactly one window for that document is visible
- **AND** no Settings window is presented

#### Scenario: Re-activating the app does not present Settings

- **WHEN** the running app is activated or reopened from the Dock while no Settings window is open
- **THEN** no Settings window is presented

### Requirement: The Settings window opens on explicit request

The app menu's Settings… command (⌘,) SHALL open the Settings window, and it MUST keep working after the launch-presentation opt-out: the first invocation after launch SHALL present the window with the full settings UI, and it SHALL re-open after the window is closed. The window's position SHALL be restored from its autosaved frame.

#### Scenario: Settings command opens the window after launch

- **WHEN** the app has launched and no Settings window is visible
- **AND** the user invokes Settings… (⌘,) from the app menu
- **THEN** the Settings window becomes visible and key with the full settings UI
- **AND** no document window is closed or otherwise disturbed

#### Scenario: Settings re-opens after being closed

- **WHEN** the user closes the Settings window and invokes Settings… again
- **THEN** the Settings window becomes visible again

### Requirement: The app declares macOS 15 as its minimum supported system version

The app SHALL declare macOS 15.0 as its minimum supported system version in every place that decides whether the app can run, so that a macOS 14 host cannot install or launch it: the SwiftPM platform declaration, the generated `Info.plist` of the runtime app bundle used during development, and the `Info.plist` of the packaged release app. The minimum is raised because the launch-presentation opt-out API exists only in macOS 15+, and SwiftUI's scene builder cannot express an availability-conditional Settings scene.

#### Scenario: Built app declares the raised minimum

- **WHEN** the app bundle is built (development runtime bundle or packaged release app)
- **THEN** its `Info.plist` declares `LSMinimumSystemVersion` 15.0
- **AND** the SwiftPM manifest declares the same platform floor

#### Scenario: Settings is reachable on the minimum supported version

- **WHEN** the app runs on macOS 15 or later
- **THEN** the Settings scene exists and the app menu's Settings… command opens it

