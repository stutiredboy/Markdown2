# preview-link-handling Specification

## Purpose

Define how link activations inside the rendered preview are routed — in-page fragments scroll natively, external links open with the system handler, local Markdown files open in Markdown2, and other local files open with their default application — while the preview itself never navigates away from the document.
## Requirements
### Requirement: The preview never navigates away from the document
The preview web view SHALL only ever display the rendered page of the current document. A link activation or new-web-view request targeting anything other than the current document's rendered page SHALL be cancelled in the web view and, when a handler may receive the target, routed to that handler; a script- or meta-initiated navigation to such a target SHALL be cancelled without invoking any handler, so a document can never auto-open anything without a user click. App-owned loads — the initial render load, reload-on-edit, document switches, and the `loadHTMLString` fallback for untitled documents — SHALL remain allowed. Back/forward navigation gestures SHALL be disabled on the preview.

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

### Requirement: Native opens require trusted input
Only trusted main-frame input observed in the isolated interaction world, or an explicit native context-menu Open action, SHALL invoke a native open handler. A `linkActivated` navigation type or a missing target frame SHALL NOT count as user authorization. Showing or cancelling a menu SHALL NOT authorize a later navigation. Page scripts SHALL NOT access the interaction handlers or the menu metadata getter.

#### Scenario: Scripted requests stay inert
- **WHEN** a page calls an anchor's `click()`, `window.open`, or assigns `location`, including a new-window anchor
- **THEN** no system handler or Markdown document window opens
- **AND** real plain, Command, and new-window anchor clicks retain their normal routing

#### Scenario: Default context menu retains native operations
- **WHEN** the user opens a link or image context menu
- **THEN** WebKit's localized Copy, Save, and Share items remain intact
- **AND** choosing Open routes the immutable link or image target captured for that menu through the same scheme policy
- **AND** cancelled, replaced-page, or unmatched menu metadata cannot be reused for another menu

#### Scenario: Referenced local image opens by explicit menu action
- **WHEN** the user chooses Open Image for a local image referenced by the current preview
- **THEN** only its exact current opaque image URL may resolve through the existing image whitelist to a file handed to the default application
- **AND** unknown tokens or URLs with altered host, path, query, or fragment do not resolve

### Requirement: In-page fragment links scroll within the document
Link activations whose target is the current document's rendered page differing only in URL fragment — heading anchors, `[TOC]` entries, footnote references and back-references, and cross-reference links — SHALL be allowed so the preview scrolls in-page without a reload.

#### Scenario: Heading anchor scrolls in place
- **WHEN** the user clicks a `[TOC]` entry or an in-document `#heading` link
- **THEN** the preview scrolls to that heading without reloading the page

#### Scenario: Footnote round trip stays in-page
- **WHEN** the user clicks a footnote reference and then its back-reference link
- **THEN** the preview scrolls to the footnote and back to the reference, staying on the document page throughout

### Requirement: External links open with the system handler
Links with an `http`, `https` or `mailto` scheme SHALL open via the system default handler for that scheme, and the preview SHALL NOT display the target.

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

### Requirement: HTML entity spelling preserves local link destinations
Before resolving a rendered link attribute against the document directory, the preview SHALL decode its semicolon-terminated numeric and named HTML character references exactly once, then parse the URL and escape the rewritten HTML attribute. Percent escapes SHALL be handled by the URL layer without an additional decoding pass. Entity-decoded same-page fragments and explicit schemes SHALL retain the existing fragment and scheme routing rules.

#### Scenario: Entity-encoded path and fragment
- **WHEN** the user clicks `[next](next&#32;chapter.md&#35;target)` (or uses `&#x23;`, `&#X23;`, or `&num;` for the fragment separator)
- **THEN** the target is `next chapter.md` with fragment `target`

#### Scenario: Entity references are not recursively expanded
- **WHEN** a link destination contains `literal&amp;num;.md`
- **THEN** the filename is `literal&num;.md` without a second expansion of `&num;`
- **AND** `literal%2523.md` targets the filename `literal%23.md`, preserving the URL layer's single percent-decoding step

### Requirement: Other local file links open with their default application
A link resolving to a local non-Markdown file SHALL open with the system default application for that file type, and the preview SHALL NOT render the file's raw contents. A relative link in an untitled document with no base directory SHALL be ignored without navigating or crashing. A resolved local link whose target is missing SHALL show a localized missing-file alert without opening another application or an empty document window.

#### Scenario: PDF link opens externally
- **WHEN** the user clicks `[spec](docs/spec.pdf)` in a saved document's preview
- **THEN** the resolved PDF opens with the system default PDF application
- **AND** the preview continues to display the current document

#### Scenario: Unresolvable relative link is ignored
- **WHEN** the user clicks a relative file link in an untitled (never-saved) document
- **THEN** the preview neither navigates nor opens anything, and the app does not crash

### Requirement: A script URL is never handed to a handler

A `javascript:` URL SHALL NOT be opened, in the preview or by any external handler. A request for one SHALL be cancelled and SHALL do nothing, including a request for a new window, which reaches the link policy before the page's Content-Security-Policy applies.

#### Scenario: New-window script link goes nowhere

- **WHEN** the user clicks a link in the preview that requests a new window for a `javascript:` URL
- **THEN** no web view is created, nothing runs, and no external handler receives the URL

#### Scenario: Scheme case does not matter

- **WHEN** a link's scheme is `JavaScript:` or any other case of `javascript:`
- **THEN** it is treated the same way

### Requirement: A link opens only what a Markdown link can

A link in the preview SHALL reach a handler only if its scheme is one a Markdown link may use: `http`, `https`, `mailto` or `file`. This SHALL hold wherever the link came from, including a link a diagram engine draws, which does not pass the check Markdown links do. A request for any other scheme SHALL be cancelled and SHALL do nothing, however it was made. Markdown links and this rule SHALL read one list of schemes.

#### Scenario: Flow link to another scheme does nothing

- **WHEN** the user clicks a `flow` link such as `st=>start: S:>ssh://example.com`
- **THEN** the preview continues to display the current document
- **AND** no handler receives the URL

#### Scenario: Mermaid link to a scheme its sanitizer keeps does nothing

- **WHEN** the user clicks a Mermaid link or label link to `tel:`, `ftp:`, `xmpp:` or another scheme Mermaid keeps and Markdown refuses
- **THEN** no handler receives the URL

#### Scenario: New-window request gets no further

- **WHEN** the user clicks a link to a refused scheme that requests a new window
- **THEN** no web view is created and no handler receives the URL

#### Scenario: Spelling does not matter

- **WHEN** a link writes a refused scheme in another case, or with a space or tab in it that the web view removes
- **THEN** it is refused the same way

#### Scenario: Diagram links Markdown allows still open

- **WHEN** the user clicks a diagram link to an `https:` or `mailto:` URL
- **THEN** it opens as the same Markdown link would


### Requirement: Cross-document heading links reveal the destination
A local Markdown link with a URL fragment SHALL open or focus the destination document and reveal the heading with that exact decoded identifier. The fragment and query SHALL NOT become part of the file URL used for saving, recovery, or recents. A link to an already-open document SHALL navigate within its latest in-memory text without reloading or discarding unsaved edits.

#### Scenario: New document and encoded heading
- **WHEN** a trusted click opens `chapter.md#%E7%9B%AE%E6%A0%87`
- **THEN** the heading with identifier `目标` is revealed after the latest document render
- **AND** its source line is revealed in Write mode and its rendered heading in Read mode

#### Scenario: Already-open dirty document
- **WHEN** the destination is already open with unsaved edits that move the heading
- **THEN** the existing window is focused and the heading is located in the unsaved text
- **AND** no text, dirty state, or undo history is changed by navigation

#### Scenario: Empty or unknown fragment
- **WHEN** the fragment is explicitly empty (`chapter.md#`)
- **THEN** the document is revealed at the top
- **WHEN** a non-empty fragment does not match a heading
- **THEN** the document stays open at its current position and a localized alert names the missing identifier

#### Scenario: Superseded request
- **WHEN** a newer link, a different document open, an outline jump, or window close happens while a heading link is waiting for rendering
- **THEN** the superseded request SHALL NOT subsequently move the viewport or show an alert

#### Scenario: Trusted missing local target
- **WHEN** a real user click targets a resolved local file that does not exist
- **THEN** the source document shows a localized missing-file alert
- **AND** synthetic clicks cannot trigger this alert or any native open handler
