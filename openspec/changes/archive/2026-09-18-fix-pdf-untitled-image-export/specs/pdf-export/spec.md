## ADDED Requirements

### Requirement: Local images embed in exported output for untitled documents

The exporter SHALL embed resolvable local image references into the exported PDF and printed output even when the document is untitled and has no base directory. An image reference that resolves without a base directory — an absolute filesystem path or a `file://` URL — SHALL be loaded through the exporter's local image scheme and SHALL appear in the output, matching the behavior of a file-backed document. A relative image reference in an untitled document has no base directory to resolve against and is not required to render.

#### Scenario: Absolute-path image appears in an untitled document's export

- **WHEN** an untitled document containing an image referenced by an absolute filesystem path is exported to PDF
- **THEN** the image appears in the PDF rather than a blank region

#### Scenario: file URL image appears in an untitled document's export

- **WHEN** an untitled document containing an image referenced by a `file://` URL is exported to PDF
- **THEN** the image appears in the PDF rather than a blank region

#### Scenario: File-backed document's local images are unchanged

- **WHEN** a file-backed document containing relative, absolute-path, and `file://` image references is exported to PDF
- **THEN** all of those images appear in the PDF exactly as before this change

#### Scenario: Relative image in an untitled document is not required to render

- **WHEN** an untitled document contains an image referenced by a relative path with no base directory to resolve it
- **THEN** the export still succeeds and the rest of the document renders normally
- **AND** the unresolved relative image is not required to appear
