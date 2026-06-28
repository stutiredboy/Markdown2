## ADDED Requirements

### Requirement: Standard menu bar follows the app language setting

The application's full menu bar — including the standard AppKit menus (File, Edit, View, Window, Help), the application menu, and their system-provided items (e.g. About, Hide, Quit, Minimize, Cut/Copy/Paste) — SHALL be presented in the language configured by the app's language setting, not the operating system locale. When the setting is "Follow System", the menu bar SHALL follow the resolved system language.

#### Scenario: Chinese setting localizes the standard menu bar

- **WHEN** the app language setting is Simplified Chinese and the app's menu bar is built
- **THEN** the standard menus and their system items are shown in Simplified Chinese
- **AND** they match the language of the already-localized custom command items

#### Scenario: English setting localizes the standard menu bar

- **WHEN** the app language setting is English and the system locale is non-English
- **THEN** the standard menus and their system items are shown in English

#### Scenario: Follow System uses the system locale

- **WHEN** the app language setting is "Follow System"
- **THEN** the standard menu bar is shown in the resolved system language

### Requirement: Language change applies to the menu bar after restart

Because the standard menu bar is built once from the active localization at launch, changing the app language in Settings SHALL inform the user that the new language applies to the menu bar after restarting the app, and SHALL offer to restart. Custom command items already update their titles immediately and SHALL continue to do so.

#### Scenario: Changing language prompts to restart

- **WHEN** the user changes the app language in Settings to a different value
- **THEN** the user is shown a localized notice that the menu bar updates after restarting
- **AND** the notice offers a way to restart the app

#### Scenario: After restart the menu bar reflects the new language

- **WHEN** the user changes the language and the app is relaunched
- **THEN** the standard menu bar is presented in the newly chosen language

#### Scenario: Custom command items update without restart

- **WHEN** the user changes the app language
- **THEN** the app's own command items (New, Open, Save, Print, Find, Mode, Outline) reflect the new language immediately, without waiting for a restart
