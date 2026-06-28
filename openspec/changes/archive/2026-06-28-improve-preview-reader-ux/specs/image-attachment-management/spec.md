## MODIFIED Requirements

### Requirement: Show missing image diagnostics in preview
The system SHALL show a visible broken-image placeholder when an image fails to load in the preview. The placeholder SHALL include the image source path or URL, remain legible in light and dark appearances, and SHALL NOT rewrite the Markdown source. The placeholder SHALL insert the failed path or URL as text rather than markup. Local image failures SHALL communicate that a local image file could not be found or loaded. Remote `http` and `https` image failures SHALL communicate that a remote image could not be loaded, rather than implying that a local file is missing. The placeholder SHALL appear only in the live preview; exported PDFs and prints SHALL NOT render it.

#### Scenario: Missing local image
- **WHEN** the Markdown contains an image reference to a missing local file
- **THEN** the preview shows a visible placeholder indicating that the local image could not be found or loaded
- **AND** the placeholder includes the missing image path

#### Scenario: Remote image unavailable
- **WHEN** the Markdown contains an image reference to an `http` or `https` URL
- **AND** the preview cannot load that remote image
- **THEN** the preview shows a visible placeholder indicating that the remote image could not be loaded
- **AND** the placeholder includes the failed image URL
- **AND** the wording does not imply that a local file path is missing

#### Scenario: Existing valid image still renders
- **WHEN** the Markdown contains an image reference to an existing local image file
- **THEN** the preview renders the image normally
- **AND** no broken-image placeholder is shown for that image

#### Scenario: Remote image loads normally
- **WHEN** the Markdown contains an image reference to an `http` or `https` URL
- **AND** the preview loads that remote image successfully
- **THEN** the preview renders the remote image normally
- **AND** no broken-image placeholder is shown for that image

#### Scenario: Diagnostic text is inert
- **WHEN** an image path or URL contains characters that could be interpreted as markup
- **AND** the image fails to load in the preview
- **THEN** the placeholder inserts the failed source as text
- **AND** the failed source does not execute script or inject markup

#### Scenario: Unknown image scheme uses generic wording
- **WHEN** the Markdown contains an image reference with a scheme other than local file handling or `http`/`https`
- **AND** the preview cannot load that image
- **THEN** the preview shows a generic image-load failure placeholder
- **AND** the wording does not imply a missing local file or a remote HTTP failure
