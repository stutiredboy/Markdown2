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
- **THEN** relaunching restores the draft and its dirty state without asking for a filename

#### Scenario: Recovery storage is unavailable
- **WHEN** writing a snapshot fails
- **THEN** the app reports the failure and keeps the document in memory
- **AND** a failed final recovery flush cancels Quit

### Requirement: Restoration preserves external changes and other drafts
Clean file-backed documents SHALL reopen current disk contents. Dirty snapshots whose backing file changed SHALL retain their text and ask the user to resolve the conflict. Missing files SHALL retain their recovery text without recreating the old path. Invalid records SHALL be left in place and reported without preventing valid records from loading. Two records for the same file SHALL preserve the extra text as an untitled draft rather than discard it or attach a second writer.

#### Scenario: Disk changed while the app was closed
- **WHEN** a dirty snapshot is restored and its recorded fingerprint differs from the disk
- **THEN** the draft remains intact and automatic overwriting is suspended

#### Scenario: Finder also opens a restored document
- **WHEN** a startup URL or argument names an already restored document
- **THEN** its existing window is shown without creating a duplicate
