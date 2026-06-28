## Purpose

Define the requirements for editor-driven image paste/drop insertion, automatic attachment storage, relative Markdown insertion, configurable attachment path, image size rendering, and preview diagnostics for missing local image assets.
## Requirements
### Requirement: Paste image data into the editor
The system SHALL allow users to paste image data from the clipboard into the Markdown editor. When the active document is file-backed, the system SHALL write the pasted image into the configured attachment directory, insert Markdown image syntax at the current selection or caret, and mark the document dirty through the normal edit pipeline.

#### Scenario: Paste screenshot into saved document
- **WHEN** the user copies a screenshot to the clipboard and pastes into a saved Markdown document
- **THEN** the system creates an image file under the configured attachment directory
- **AND** the editor inserts a Markdown image reference using a relative path to that file
- **AND** the document is marked dirty

#### Scenario: Paste replaces selected text
- **WHEN** the editor has selected text and the user pastes an image from the clipboard
- **THEN** the selected text is replaced by the generated Markdown image reference
- **AND** the image file is created before the reference is inserted

#### Scenario: Unsupported clipboard content falls back
- **WHEN** the clipboard does not contain image data or image file URLs
- **THEN** the editor preserves its existing paste behavior

#### Scenario: Paste is available for an image-only clipboard
- **WHEN** the clipboard holds image data but no text
- **THEN** the Paste command is enabled so the image can be inserted

#### Scenario: Pasted image file reference links in place
- **WHEN** the clipboard holds an image file reference (for example, a file copied in Finder)
- **THEN** the editor inserts a reference to that file's existing location
- **AND** the system does not copy the file into the attachment directory

### Requirement: Drop image files into the editor
The system SHALL allow users to drag supported local image files into the Markdown editor. Because a dropped file already exists on disk, the system SHALL insert a Markdown image reference to each file's existing location, without copying it, at the drop insertion point or current caret. The inserted reference SHALL use the file's absolute path, link-safe (e.g., spaces percent-encoded) so it renders. A dropped image does not require the document to be saved first.

#### Scenario: Drop one image file
- **WHEN** the user drops a supported image file onto a Markdown document
- **THEN** the editor inserts a Markdown image reference to the file's existing location
- **AND** the system does not copy the file into the attachment directory

#### Scenario: Drop multiple image files
- **WHEN** the user drops multiple supported image files onto the editor
- **THEN** the editor inserts one Markdown image reference per file in drop order
- **AND** each reference points to that file's existing location

#### Scenario: Drop into an untitled document
- **WHEN** the user drops a supported image file into a document that has never been saved
- **THEN** the editor inserts the reference without prompting to save the document

#### Scenario: Linked image outside the document folder displays in preview
- **WHEN** a saved document references a local image by an absolute path outside the document's own folder
- **THEN** the preview displays that image rather than a broken-image placeholder

#### Scenario: Drop unsupported file
- **WHEN** the user drops a file that is not a supported image
- **THEN** the system SHALL NOT insert an image reference for that file
- **AND** the existing editor behavior for unsupported drops is preserved

### Requirement: Store pasted clipboard images in a configurable document-relative folder
The system SHALL store pasted clipboard image data (which has no source location) in a document-relative folder. Dropped or pasted image *files* are linked in place and are not stored here. The default folder SHALL be `assets`. Users SHALL be able to configure the folder path in Settings, and the configured value SHALL persist across launches. The system SHALL reject or normalize values that would resolve outside the Markdown document's directory. If creating the folder or writing the image fails, the system SHALL surface an error and SHALL NOT insert an image reference.

#### Scenario: Default attachment folder
- **WHEN** the user has not configured an attachment folder and inserts an image into a saved document
- **THEN** the system stores the image under an `assets` folder beside the Markdown file

#### Scenario: Configured nested attachment folder
- **WHEN** the user configures the attachment folder as `images/screenshots`
- **AND** the user inserts an image into a saved document
- **THEN** the system stores the image under `images/screenshots` beside the Markdown file
- **AND** the inserted Markdown path points to that relative folder

#### Scenario: Invalid attachment folder
- **WHEN** the configured attachment folder is absolute or contains path traversal outside the document directory
- **THEN** the system uses the default `assets` folder instead
- **AND** no image is written outside the document directory

#### Scenario: Attachment write fails
- **WHEN** the configured attachment folder cannot be created or the image cannot be written (for example, a read-only location)
- **THEN** the system surfaces an error
- **AND** does not insert an image reference

### Requirement: Require saving untitled documents before storing clipboard images
The system SHALL require an untitled document to be saved before it writes pasted clipboard image data into the document-relative folder. (Dropped or pasted image files are linked in place and do not require a save.) If the user cancels the save prompt or saving fails, the system SHALL NOT create an attachment and SHALL NOT insert an image reference.

#### Scenario: Save untitled document before storing a pasted clipboard image
- **WHEN** the user pastes a clipboard image (a screenshot) into an untitled document
- **AND** the user completes the save prompt
- **THEN** the system writes the Markdown document to the chosen location
- **AND** stores the pasted image under the configured attachment folder beside that location
- **AND** inserts a relative Markdown image reference

#### Scenario: Cancel save for untitled document
- **WHEN** the user pastes a clipboard image into an untitled document
- **AND** the user cancels the save prompt
- **THEN** the system does not create an image file
- **AND** the editor content remains unchanged by the image insertion request

### Requirement: Generate collision-safe portable image paths
The system SHALL generate destination filenames that are safe for Markdown references and do not overwrite existing files. When a generated destination already exists, the system SHALL append a numeric suffix or otherwise choose a unique filename. Inserted Markdown references SHALL be relative to the Markdown document directory and SHALL parse as Markdown image links (for example, they SHALL NOT contain an unescaped space that would prevent the link from rendering).

#### Scenario: Filename collision
- **WHEN** the configured attachment directory already contains `diagram.png`
- **AND** the user drops another image whose sanitized filename would be `diagram.png`
- **THEN** the system stores the new image using a unique filename such as `diagram-2.png`
- **AND** the inserted Markdown path points to the new file

#### Scenario: Portable relative path
- **WHEN** the user inserts any image attachment into a saved document
- **THEN** the inserted Markdown image reference uses a relative path
- **AND** the inserted Markdown image reference does not contain an absolute filesystem path

#### Scenario: Unsafe characters in source filename are sanitized
- **WHEN** the user drops an image whose filename contains spaces or characters unsafe for a Markdown link
- **THEN** the stored filename and inserted reference are sanitized so the link parses as an image
- **AND** the rendered preview shows the image rather than literal `![…](…)` text

### Requirement: Render image size attributes
The system SHALL render numeric image size attributes attached to Markdown image syntax. The supported syntax SHALL be an attribute block immediately following the image, such as `![alt](path){width=320}` or `![alt](path){width=320 height=180}`. Valid numeric attributes SHALL be emitted as image dimensions in the preview; invalid attributes SHALL be ignored and the base image SHALL still render.

#### Scenario: Width attribute renders
- **WHEN** the Markdown contains `![diagram](assets/diagram.png){width=480}`
- **THEN** the preview renders the image with a width of 480 pixels
- **AND** the literal `{width=480}` text is not shown after the image

#### Scenario: Width and height attributes render
- **WHEN** the Markdown contains `![photo](assets/photo.jpg){width=320 height=180}`
- **THEN** the preview renders the image with width 320 pixels and height 180 pixels
- **AND** the literal attribute block is not shown after the image

#### Scenario: Width-only attribute preserves aspect ratio
- **WHEN** the Markdown contains `![diagram](assets/diagram.png){width=480}` with no height
- **THEN** the preview renders the image at width 480 with its natural aspect ratio preserved
- **AND** the image is not distorted to a fixed height

#### Scenario: Explicit attribute overrides size encoded in the URL
- **WHEN** the Markdown contains `![photo](assets/photo-1200x800.png){width=480}`
- **THEN** the preview sizes the image from the explicit `{width=480}` attribute
- **AND** the dimensions inferred from the URL pattern do not override it

#### Scenario: Invalid size attribute is ignored
- **WHEN** the Markdown contains `![photo](assets/photo.jpg){width=large}`
- **THEN** the preview renders the image normally
- **AND** the invalid size attribute does not produce unsafe HTML attributes

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

### Requirement: Preserve existing image rendering behavior
The system SHALL preserve existing image rendering for authored Markdown image links that do not use new size attributes or attachment insertion flows.

#### Scenario: Existing relative image link
- **WHEN** an existing document contains `![alt](images/existing.png)`
- **THEN** the preview renders the same image markup behavior as before this change when the file is loadable

#### Scenario: Existing titled image link
- **WHEN** an existing document contains `![alt](images/existing.png "Title")`
- **THEN** the preview preserves the image title behavior
- **AND** the new attachment workflow does not alter the source text unless the user explicitly inserts a new image

#### Scenario: Existing URL-inferred image dimensions still apply
- **WHEN** an existing document contains an image whose URL encodes dimensions, such as `![sample](https://example.com/200x100.png)`
- **THEN** the preview still reserves layout space from the URL-inferred dimensions
- **AND** the new attribute syntax does not change that behavior when no `{...}` block is present

