## MODIFIED Requirements

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

### Requirement: External links open with the system handler
Links with an `http`, `https` or `mailto` scheme SHALL open via the system default handler for that scheme, and the preview SHALL NOT display the target.

#### Scenario: Web link opens in the default browser
- **WHEN** the user clicks `[site](https://example.com)` in the preview
- **THEN** `https://example.com` opens in the user's default browser

#### Scenario: Mail link opens the mail handler
- **WHEN** the user clicks a `mailto:someone@example.com` link
- **THEN** the system default mail handler is invoked for that address

## ADDED Requirements

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
