## ADDED Requirements

### Requirement: A script URL is never handed to a handler

A `javascript:` URL SHALL NOT be opened, in the preview or by any external handler. A request for one SHALL be cancelled and SHALL do nothing, including a request for a new window, which reaches the link policy before the page's Content-Security-Policy applies.

#### Scenario: New-window script link goes nowhere

- **WHEN** the user clicks a link in the preview that requests a new window for a `javascript:` URL
- **THEN** no web view is created, nothing runs, and no external handler receives the URL

#### Scenario: Scheme case does not matter

- **WHEN** a link's scheme is `JavaScript:` or any other case of `javascript:`
- **THEN** it is treated the same way
