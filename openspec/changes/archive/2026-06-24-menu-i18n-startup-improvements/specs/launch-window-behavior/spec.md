## ADDED Requirements

### Requirement: Direct launch does not open a blank document by default

When the app is launched directly with no file to open (no file argument, not via Finder), the app SHALL NOT automatically create a blank starter document window unless the user has enabled the corresponding preference. The app SHALL still finish launching and activate normally with its menu bar available.

#### Scenario: Direct launch with the preference disabled opens no document

- **WHEN** the app is launched directly with no file argument and the "open a blank document on launch" preference is disabled
- **THEN** no blank document window is created
- **AND** the app activates with its menu bar available so the user can use New or Open

#### Scenario: Opening a file at launch is unaffected

- **WHEN** the app is launched with a file argument or a file is opened via Finder
- **THEN** that file is opened in a document window regardless of the launch preference

### Requirement: Opening a blank document on launch is configurable

The app SHALL expose a preference, defaulting to disabled, that controls whether direct launch opens a blank starter document. When enabled, direct launch with no file SHALL create one blank document window using the new-document presentation mode. The preference SHALL persist across launches and SHALL be labeled in English and Simplified Chinese in Settings.

#### Scenario: Enabling the preference restores blank-document launch

- **WHEN** the user enables the "open a blank document on launch" preference and launches the app directly with no file
- **THEN** a single blank document window is created in the configured new-document mode
- **AND** the preference persists after relaunching the app

#### Scenario: Default value is disabled

- **WHEN** no value for the preference has ever been saved
- **THEN** the preference resolves to disabled and direct launch opens no blank document

### Requirement: Dock-icon reopen still creates a document when needed

Independent of the launch preference, when the user reactivates the app from the Dock (or via app reopen) and no document windows are open, the app SHALL create a new blank document so reactivation always yields a usable window.

#### Scenario: Reopen with no windows creates a document

- **WHEN** the app has no open document windows and the user clicks its Dock icon
- **THEN** a new blank document window is created and brought to the front
