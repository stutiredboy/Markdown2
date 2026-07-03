## ADDED Requirements

### Requirement: Document failure alerts render in the app language
All document-level failure alerts — open failure, undecodable file, save failure, PDF/HTML/DOCX/EPUB export failure, print failure, Pandoc-unavailable guidance, and image-attachment write failure — SHALL present their message text in the app's effective language (English or Simplified Chinese, following the existing language setting). File names and export formats SHALL be interpolated into the localized message. The underlying system error description MAY remain in the alert's detail text as diagnostic information.

#### Scenario: Open failure in Chinese
- **WHEN** the app language is Simplified Chinese and opening a file fails
- **THEN** the alert's message is in Simplified Chinese and names the file

#### Scenario: Pandoc guidance in the app language
- **WHEN** the app language is Simplified Chinese and the user invokes DOCX/EPUB export without Pandoc installed
- **THEN** the alert explains in Simplified Chinese that Pandoc is required and how to proceed

#### Scenario: English remains the default
- **WHEN** the app language is English (or follows an English system)
- **THEN** every document failure alert renders its existing English copy

### Requirement: No hard-coded alert copy in the document layer
The document layer SHALL obtain all alert copy through the app's localization table via an injected provider, so no user-facing alert string is hard-coded at the alert construction site. Tests SHALL be able to inject a fixed provider.

#### Scenario: Alert copy comes from the localization table
- **WHEN** any document failure alert is constructed
- **THEN** its message text is resolved through the localization table for the effective language
