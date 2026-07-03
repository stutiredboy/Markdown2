## ADDED Requirements

### Requirement: The preview never navigates away from the document
The preview web view SHALL only ever display the rendered page of the current document. A link activation or new-web-view request targeting anything other than the current document's rendered page SHALL be cancelled in the web view and routed to an appropriate external handler; a script- or meta-initiated navigation to such a target SHALL be cancelled without invoking any handler, so a document can never auto-open anything without a user click. App-owned loads — the initial render load, reload-on-edit, document switches, and the `loadHTMLString` fallback for untitled documents — SHALL remain allowed. Back/forward navigation gestures SHALL be disabled on the preview.

#### Scenario: External link click keeps the document on screen
- **WHEN** the user clicks an `https://` link in the rendered preview
- **THEN** the preview continues to display the current document unchanged
- **AND** the link opens in the user's default browser

#### Scenario: Render reloads still load
- **WHEN** an edit in Read mode triggers a full preview reload of the app's rendered page
- **THEN** the reload is allowed and the preview shows the updated render

#### Scenario: New-window link requests are routed, not dropped
- **WHEN** the user clicks a link that requests a new browsing context (`target="_blank"` or Cmd+click)
- **THEN** no new web view is created inside the app
- **AND** the target is routed exactly as a plain click on the same URL would be

### Requirement: In-page fragment links scroll within the document
Link activations whose target is the current document's rendered page differing only in URL fragment — heading anchors, `[TOC]` entries, footnote references and back-references, and cross-reference links — SHALL be allowed so the preview scrolls in-page without a reload.

#### Scenario: Heading anchor scrolls in place
- **WHEN** the user clicks a `[TOC]` entry or an in-document `#heading` link
- **THEN** the preview scrolls to that heading without reloading the page

#### Scenario: Footnote round trip stays in-page
- **WHEN** the user clicks a footnote reference and then its back-reference link
- **THEN** the preview scrolls to the footnote and back to the reference, staying on the document page throughout

### Requirement: External links open with the system handler
Links with a non-file scheme (`http`, `https`, `mailto`, and any other external scheme) SHALL open via the system default handler for that scheme, and the preview SHALL NOT display the target.

#### Scenario: Web link opens in the default browser
- **WHEN** the user clicks `[site](https://example.com)` in the preview
- **THEN** `https://example.com` opens in the user's default browser

#### Scenario: Mail link opens the mail handler
- **WHEN** the user clicks a `mailto:someone@example.com` link
- **THEN** the system default mail handler is invoked for that address

### Requirement: Local Markdown links open in Markdown2
A link resolving to a local file with an `md` or `markdown` path extension (case-insensitive) SHALL open in Markdown2 through the standard open-file path: an existing window showing that file is brought to the front, otherwise a reusable untouched starter window is loaded or a new window is created.

#### Scenario: Relative Markdown link opens in a window
- **WHEN** the current document contains `[next](chapter2.md)` and the user clicks it
- **THEN** `chapter2.md` (resolved against the document's directory) opens in a Markdown2 window

#### Scenario: Already-open Markdown link fronts the existing window
- **WHEN** the linked Markdown file is already open in another window
- **THEN** that window is brought to the front instead of opening a duplicate

### Requirement: Other local file links open with their default application
A link resolving to a local non-Markdown file SHALL open with the system default application for that file type, and the preview SHALL NOT render the file's raw contents. A relative link that cannot be resolved to a file (an untitled document with no base directory, or a missing target) SHALL be ignored without navigating or crashing.

#### Scenario: PDF link opens externally
- **WHEN** the user clicks `[spec](docs/spec.pdf)` in a saved document's preview
- **THEN** the resolved PDF opens with the system default PDF application
- **AND** the preview continues to display the current document

#### Scenario: Unresolvable relative link is ignored
- **WHEN** the user clicks a relative file link in an untitled (never-saved) document
- **THEN** the preview neither navigates nor opens anything, and the app does not crash
