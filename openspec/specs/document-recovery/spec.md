# document-recovery Specification

## Purpose

Bound the unsaved-edit interval and restore open documents after application termination.

## Requirements

### Requirement: Autosave has an idle delay and a maximum waiting time
File-backed documents SHALL autosave after 5 seconds of idle time or at most 30 seconds after the first unsaved edit during continuous typing. External conflicts, missing backing files, and unrepresentable characters SHALL prevent unsafe writes without preventing recovery snapshots.

#### Scenario: Continuous input
- **WHEN** the user types without a 5-second pause
- **THEN** a safe file-backed document is saved within 30 seconds of the first pending edit

### Requirement: Every open document has a durable recovery record
The app SHALL write atomic, per-document snapshots in its Application Support directory. Editing SHALL throttle snapshots to one write per second without postponing the deadline on each keystroke. Snapshots SHALL retain full Unicode text, byte format, file identity, disk fingerprint, dirty state, and window geometry.

#### Scenario: Untitled draft survives a crash
- **WHEN** an untitled document has a successfully written snapshot and the app is forcibly terminated
- **THEN** launching the app without an explicit file request restores the draft and its dirty state without asking for a filename

#### Scenario: Recovery storage is unavailable
- **WHEN** writing a snapshot fails
- **THEN** the app reports the failure and keeps the document in memory
- **AND** a failed final recovery flush cancels Quit

### Requirement: Restoration preserves external changes and other drafts
Clean file-backed documents SHALL reopen current disk contents. Dirty snapshots whose backing file changed SHALL retain their text and ask the user to resolve the conflict. Missing files SHALL retain their recovery text without recreating the old path. Invalid records SHALL be left in place and reported without preventing valid records from loading. Two records for the same file SHALL preserve the extra text as an untitled draft rather than discard it or attach a second writer.

#### Scenario: Disk changed while the app was closed
- **WHEN** a dirty snapshot is restored and its recorded fingerprint differs from the disk
- **THEN** the draft remains intact and automatic overwriting is suspended

### Requirement: Explicit file opens do not restore unrelated windows
Launching with Finder URLs or a file argument SHALL open only the requested documents. The newest matching recovery record SHALL supply unsaved edits for each requested file. Other records, including untitled drafts and additional versions of the requested file, SHALL remain on disk for an ordinary app launch without an explicit file request. Opening a deferred file later in the same process SHALL restore its record, resolving file identity before matching the path. Opening an already open document SHALL select its existing window.

#### Scenario: Finder opens a new file after a multi-window session
- **GIVEN** recovery records for an untitled draft and two other files
- **WHEN** Finder launches the app to open a fourth file
- **THEN** only the fourth file is presented
- **AND** the three unrelated recovery records remain unchanged after Quit
- **AND** a later ordinary app launch restores the retained drafts and windows

#### Scenario: Requested file has unsaved edits
- **WHEN** a startup URL or argument names a file with a dirty recovery record
- **THEN** one window presents its recovered text and dirty state
- **AND** unrelated records are not opened

#### Scenario: Deferred file is renamed before opening
- **WHEN** a file whose recovery was deferred is renamed and explicitly opened later in the same process
- **THEN** its recovered edits follow the new path
- **AND** repeated opens select the same window without creating another writer
