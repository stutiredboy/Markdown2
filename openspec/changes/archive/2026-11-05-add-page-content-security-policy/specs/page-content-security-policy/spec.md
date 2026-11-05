## ADDED Requirements

### Requirement: Every rendered page carries a Content-Security-Policy

Every page `MarkdownRenderer` produces SHALL carry a Content-Security-Policy ahead of every stylesheet, script and piece of document content. This covers the preview, the page that PDF export and Print render, and an exported HTML file. The policy SHALL let run only the scripts the page was built with: each inline script by its SHA-256 hash, and each served engine by its exact URL. Its `script-src` SHALL NOT contain `'unsafe-inline'` or `'unsafe-eval'`. It SHALL close every resource type it does not name, and SHALL close `base-uri` and `form-action`. Rendering the same input twice SHALL produce the same page.

#### Scenario: Policy precedes what it governs

- **WHEN** any page is rendered
- **THEN** the policy comes before the page's first stylesheet, script and document content

#### Scenario: Only the page's own scripts are named

- **WHEN** a page is rendered
- **THEN** `script-src` holds one source for each script in the page and nothing else
- **AND** an engine the page does not use is not named

#### Scenario: Document text cannot add to the policy

- **WHEN** a document contains a `<meta>` tag naming a policy, or text that closes the page's `<head>`
- **THEN** that text stays escaped and the page has exactly one policy

#### Scenario: Rendering stays deterministic

- **WHEN** the same document is rendered twice with the same configuration
- **THEN** the two pages are identical

### Requirement: Document content cannot run script

Nothing in a document SHALL run script in a rendered page, on any diagram engine, whether or not the reader clicks anything and even if its markup gets past `HTMLSafety` or an engine's sanitizing.

#### Scenario: Flow script link does not run

- **WHEN** a `flow` block gives a node a `javascript:` link and the reader clicks it, in the preview, on the PDF page, or in an exported file
- **THEN** no script runs

#### Scenario: Flow script link in a new window does not run

- **WHEN** a `flow` block gives a node a `javascript:` link with the `[blank]` target and the reader clicks it
- **THEN** no script runs, in the page or in any window the link opens

#### Scenario: Injected markup does not run

- **WHEN** an event handler, a `<script>` element, a frame, an `<object>`, an `<embed>`, a form or a link holding script reaches the page
- **THEN** none of it runs script

#### Scenario: Eval is off

- **WHEN** code in a rendered page calls `eval`, `new Function`, or `setTimeout` with a string
- **THEN** the code does not run

#### Scenario: What the policy does not name is refused

- **WHEN** a page requests something the policy does not name, such as a `fetch` or a media element's source
- **THEN** the request is refused

#### Scenario: A page cannot move its base URL

- **WHEN** a `<base>` element reaches the page
- **THEN** the page's base URL does not change

### Requirement: The policy leaves the page working

Under the policy, math and every diagram engine SHALL render without `eval`, and the app's own scripts SHALL keep working: the preview's user scripts and native calls, live updates, and PDF print overrides. A page that renders normally SHALL produce no policy violation.

#### Scenario: Every engine renders

- **WHEN** a page holds math, chemistry, a `flow` block, a `sequence` block, and each Mermaid diagram type
- **THEN** each one renders on all three surfaces, and the policy refuses nothing

#### Scenario: Preview scripts work

- **WHEN** the preview applies typography, hides front matter, shows line numbers, captures its scroll anchor, or runs a find
- **THEN** each takes effect, and the policy refuses nothing

#### Scenario: Live update renders under the loaded policy

- **WHEN** a live update adds math and diagrams of engines the page already has
- **THEN** the new content renders without a page load, and the policy refuses nothing

#### Scenario: A new engine brings its own policy

- **WHEN** an edit adds a diagram whose engine the page does not have
- **THEN** a full load shows a page whose policy names that engine, and the diagram renders

#### Scenario: Print overrides apply

- **WHEN** the PDF page is shown
- **THEN** the print overrides take effect, and the policy refuses nothing

### Requirement: Images keep loading

The policy SHALL keep `img-src` open to `http` and `https`, so remote images load as they did. It SHALL allow `data:` images, a document's local images on app pages, and `file:` images in an exported file. It does not stop a document naming a remote image.

#### Scenario: Remote Markdown image loads

- **WHEN** a document holds a Markdown image with an `http` or `https` URL
- **THEN** the image loads on all three surfaces

#### Scenario: Image in a diagram label loads

- **WHEN** a Mermaid label holds an `<img>` with a remote URL
- **THEN** the image loads, as a Markdown image does

#### Scenario: Embedded image in an exported file

- **WHEN** HTML export embeds a local image as a `data:` URI
- **THEN** the image loads in the exported file

#### Scenario: Image left beside an exported file

- **WHEN** an unsaved document's relative image is left as written in an exported file, and the image sits beside that file
- **THEN** the image loads in the exported file
