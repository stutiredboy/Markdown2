## MODIFIED Requirements

### Requirement: Export as self-contained HTML

The app SHALL provide a command to export the rendered document as a single HTML
file. All styles, the math and diagram engines, and every image the export can
embed SHALL be inside the file, so it needs no sidecar files. The exported file
SHALL open and display correctly with no external files and no network access,
except for the images the export reports as not embedded and any image a diagram's
own source loads when the file is displayed. Like PDF export, HTML export SHALL be
a derived artifact: it SHALL NOT change the document's `fileURL`,
dirty state, or autosave, and the pending render SHALL be flushed first so the
export reflects the latest text.

#### Scenario: Export produces a single file

- **WHEN** the user invokes Export as HTML and chooses a destination
- **THEN** a single `.html` file is written to that destination
- **AND** no sidecar asset files are created next to it

#### Scenario: Exported HTML opens offline

- **WHEN** a document is exported to HTML with no images reported as not embedded
- **AND** none of its diagrams loads an image from its own source
- **AND** the file is opened in a browser with no network access
- **THEN** the document content, styles, math, diagrams, and images all display correctly

#### Scenario: Reported images do not affect the rest of the file

- **WHEN** a document is exported to HTML and some images are reported as not embedded
- **AND** the file is opened in a browser with no network access
- **THEN** the document content, styles, math, diagrams, and embedded images display correctly

#### Scenario: Export does not alter the document

- **WHEN** the user exports HTML
- **THEN** the document's saved file, dirty indicator, and autosave are unaffected

### Requirement: Local images are inlined; remote images preserved

The self-contained HTML export SHALL inline images referenced by local relative or
absolute paths as embedded data so they display without the original files.
Images referenced by remote `http`/`https` URLs SHALL be left as URLs and SHALL NOT
be fetched at export time. A local reference that cannot be embedded SHALL be left
as-is rather than failing the export: this covers a missing or unreadable file, a
file that is not an image, and, when the document has no file location (untitled),
a relative path that cannot be resolved.

#### Scenario: Local image is embedded

- **WHEN** a document references a local image by a relative path and is exported to HTML
- **THEN** the image is embedded in the HTML and displays when the file is opened elsewhere

#### Scenario: Remote image URL is preserved

- **WHEN** a document references an image by an `https` URL and is exported to HTML
- **THEN** the exported HTML keeps the `https` URL for that image

#### Scenario: Untitled document exports without failing on images

- **WHEN** an untitled document containing a relative image reference is exported to HTML
- **THEN** the export succeeds
- **AND** the image reference is left as-is (not inlined, since the file path cannot be resolved)

#### Scenario: Missing local image does not fail the export

- **WHEN** a saved document references a local image file that does not exist and is exported to HTML
- **THEN** the export succeeds
- **AND** the image reference is left as-is

## ADDED Requirements

### Requirement: Export reports images it did not embed

After writing the file, the app SHALL show one notice, in the app language, naming
the images that are not embedded in it. The notice SHALL separate remote images,
which need the network, from local images that could not be embedded. Each image
SHALL be named once, in document order, however many times the document uses it.
Each group SHALL name at most five images and state how many more are not named.

The app SHALL NOT show the notice when every image is embedded. An image that is
already a `data:` URI SHALL count as embedded. Text in the page's own scripts or
styles that resembles an image tag SHALL NOT count as an image. When the file
cannot be written, the app SHALL report that failure and SHALL NOT show the notice.

The notice covers Markdown images and raw HTML `<img>` tags. Diagram source reaches
its engine unchanged, so an image it loads when the file is displayed, such as an
`<img>` in a Mermaid label, SHALL be neither embedded nor named.

#### Scenario: Remote and missing images are listed

- **WHEN** a saved document with an `https` image and a missing local image is exported to HTML
- **THEN** the file is written
- **AND** one notice names both images, in separate groups

#### Scenario: Untitled document's relative image is listed

- **WHEN** an untitled document containing a relative image reference is exported to HTML
- **THEN** the file is written
- **AND** the notice names that image among the local images

#### Scenario: Fully embedded document shows no notice

- **WHEN** a document whose images are all local files or `data:` URIs is exported to HTML
- **THEN** the file is written
- **AND** no notice is shown

#### Scenario: Document with no images shows no notice

- **WHEN** a document with no images is exported to HTML
- **THEN** no notice is shown, even though the embedded math engine's script contains text resembling an image tag

#### Scenario: Long lists are capped

- **WHEN** a document with eight distinct remote images is exported to HTML
- **THEN** the notice names the first five
- **AND** it states that three more are not named

#### Scenario: Repeated image is named once

- **WHEN** a document uses the same missing image twice and is exported to HTML
- **THEN** the notice names that image once

#### Scenario: Image in diagram source is not named

- **WHEN** a Mermaid diagram's label contains an `<img>` tag and the document is exported to HTML
- **THEN** the diagram source is left unchanged
- **AND** the notice does not name that image

#### Scenario: Failed write shows no notice

- **WHEN** the file cannot be written to the chosen destination
- **THEN** the app reports that the export failed
- **AND** the notice about images is not shown
