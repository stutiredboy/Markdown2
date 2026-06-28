## Purpose

Define the user-configurable export profile that controls page geometry, page numbers, and header/footer text for PDF export and Print, and its persistence and Settings UI.

## Requirements

### Requirement: Persisted export profile

The app SHALL maintain a single export profile that holds the page size,
orientation, margins, page-number setting, and header/footer configuration. The
profile SHALL be persisted across app launches. On first launch (no stored
profile), the profile SHALL default to A4 portrait with narrow margins, page
numbers off, and headers/footers off, so default export output is unchanged from
before this change.

#### Scenario: Profile persists across launches

- **WHEN** the user changes a profile setting and relaunches the app
- **THEN** the changed setting is still in effect after relaunch

#### Scenario: Default profile reproduces prior output

- **WHEN** the app is launched with no previously stored profile
- **THEN** the profile is A4 portrait, narrow margins, page numbers off, headers/footers off

### Requirement: Page size and orientation presets

The profile SHALL let the user choose a page size from a set of named presets
(SHALL include at least A4 and Letter) and an orientation of portrait or
landscape. Landscape SHALL produce pages whose width exceeds their height for the
selected size.

#### Scenario: Selecting a page size preset

- **WHEN** the user selects the Letter page size in the profile
- **THEN** subsequent PDF exports use Letter-sized pages

#### Scenario: Selecting landscape orientation

- **WHEN** the user selects landscape orientation
- **THEN** subsequent PDF exports produce pages wider than they are tall

### Requirement: Margin presets and custom margins

The profile SHALL offer margin presets (SHALL include Normal, Narrow, Wide, and
None) and SHALL allow custom per-side margins. The selected margins SHALL
determine the printable area used for layout and pagination.

#### Scenario: Selecting a margin preset

- **WHEN** the user selects the Wide margin preset
- **THEN** subsequent PDF exports lay content within wide margins on every side

#### Scenario: Setting custom margins

- **WHEN** the user enters custom per-side margins
- **THEN** subsequent PDF exports use exactly those margins for each side

### Requirement: Header and footer configuration with tokens

The profile SHALL let the user enable page numbers and enable header and/or footer
text. Header and footer text SHALL be configurable per left/center/right zone and
SHALL support substitution tokens for the document title, the current date, the
page number, and the total page count.

#### Scenario: Enabling page numbers

- **WHEN** the user enables page numbers in the profile
- **THEN** subsequent PDF exports include page numbers

#### Scenario: Configuring footer text with a token

- **WHEN** the user sets the footer center text to a template containing the page token
- **THEN** subsequent PDF exports render the resolved page number in the footer center

### Requirement: Profile applies to both PDF export and Print

The active profile SHALL be applied to both PDF export and Print, so that printed
output and exported PDFs share the same page geometry, page numbers, and
headers/footers. When printing, the print dialog SHALL open pre-configured with
the profile's page size and orientation, so the user is not surprised by a
mismatch between the configured size and the system default paper size.

#### Scenario: Print honors the profile

- **WHEN** the profile selects Letter size with page numbers enabled and the user prints
- **THEN** the printed output uses Letter-sized pages with page numbers

#### Scenario: Print dialog opens with the profile's page size

- **WHEN** the profile selects Letter size and the user opens the print dialog
- **THEN** the print dialog's paper size is set to Letter
- **AND** the user is not required to manually change the paper size to match the profile

#### Scenario: Export and print are consistent

- **WHEN** the same document is exported to PDF and printed with the same profile
- **THEN** both outputs have identical page geometry, page numbers, and headers/footers

### Requirement: Localized export settings UI

The export profile SHALL be editable from the app Settings, and all of its labels
and help text SHALL be localized in the app's supported languages (English and
Simplified Chinese), consistent with the rest of Settings.

#### Scenario: Settings exposes the profile

- **WHEN** the user opens Settings
- **THEN** an export section lets the user view and change page size, orientation, margins, page numbers, and header/footer settings

#### Scenario: Labels follow the app language

- **WHEN** the app language is Simplified Chinese
- **THEN** the export settings labels and help text are shown in Simplified Chinese

### Requirement: Export operations are mutually exclusive

PDF export, Print, and HTML export SHALL be mutually exclusive: starting one while
another is in progress SHALL be ignored. This prevents concurrent file-generation
operations from conflicting over save panels or producing inconsistent output from
a mid-edit document.

#### Scenario: Second export is ignored while one is in progress

- **WHEN** a PDF export is in progress and the user invokes Export as HTML
- **THEN** the HTML export is not started
- **AND** the in-progress PDF export continues unaffected
