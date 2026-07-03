# recent-documents Specification

## Purpose

Define recording of recently opened and saved documents in app-owned persistent storage, the localized File ▸ Open Recent submenu (launch snapshot), the live Dock-menu recents, Clear Menu, and pruning of missing files.

## Requirements
### Requirement: Opens and first saves record recent documents
The app SHALL record a document as recent on every successful file open (open panel, Finder, launch argument, linked-file open) and on the first successful save of an untitled document. The list SHALL persist across app launches for any build, in app-owned storage (macOS declines the system recents service's persistence for unsigned/ad-hoc builds, and in-session system noting would duplicate the app's own Dock recents — so the system service is not used). Recording SHALL respect the system "Recent items" count limit.

#### Scenario: Opened file appears in recents
- **WHEN** the user opens a Markdown file by any open path
- **THEN** that file appears at the top of the persisted recents list
- **AND** at the top of the Dock menu's recents within the same session

#### Scenario: First save of an untitled document is recorded
- **WHEN** an untitled document is saved for the first time
- **THEN** the saved file appears at the top of File ▸ Open Recent

#### Scenario: Recents persist across relaunch
- **WHEN** the app is quit and relaunched
- **THEN** File ▸ Open Recent lists the same documents in the same order

### Requirement: Open Recent submenu lists and reopens documents
The File menu SHALL contain an "Open Recent" submenu, localized in the app language, listing recent documents most-recent-first with duplicates (same standardized path) collapsed to one entry. Entries SHALL show the file's display name; entries whose names collide SHALL be disambiguated with their parent folder. Selecting an entry SHALL open the document through the standard open path: an existing window showing that file is brought to the front, otherwise a reusable starter window or a new window is used. The submenu's displayed list reflects the persisted recents as of app launch (the app's SwiftUI command tree is not re-evaluated while the Settings scene is closed, so in-session list changes appear on the next launch; the Dock menu serves the live list — see the Dock menu requirement).

#### Scenario: Selecting a recent opens or fronts the document
- **WHEN** the user selects a recent entry whose file is already open in a window
- **THEN** that window is brought to the front without opening a duplicate

#### Scenario: Submenu is localized
- **WHEN** the app language is Simplified Chinese
- **THEN** the submenu title and its Clear Menu item render in Simplified Chinese

#### Scenario: Previous session's files are listed at launch
- **WHEN** the app is launched after a session in which documents were opened
- **THEN** File ▸ Open Recent lists those documents most-recent-first

### Requirement: Dock menu serves the live recents list
The Dock icon's context menu SHALL list the current recent documents (same order and titles as the submenu model), rebuilt on every open of the Dock menu, so the list is live within the running session. Selecting a Dock entry SHALL open the document through the standard open path.

#### Scenario: Newly opened file appears in the Dock menu without relaunch
- **WHEN** the user opens a file and then right-clicks the app's Dock icon in the same session
- **THEN** the file is listed at the top of the Dock menu's recents

### Requirement: Clear Menu and missing files
The Open Recent submenu SHALL end with a "Clear Menu" item that empties the persisted recent-documents list. Selecting a recent entry whose file no longer exists SHALL show the localized open-failure notice and remove that entry from the persisted list, leaving the remaining entries intact. List changes take effect immediately in storage and the Dock menu; the File submenu shows them from the next launch.

#### Scenario: Clear Menu empties the list
- **WHEN** the user chooses Clear Menu
- **THEN** the persisted recents list is empty
- **AND** the Open Recent submenu is empty (aside from the disabled Clear Menu item) on the next launch

#### Scenario: Missing file is pruned
- **WHEN** the user selects a recent entry whose file was deleted
- **THEN** a localized notice explains the file could not be opened
- **AND** the entry is removed from the persisted list while other entries remain

