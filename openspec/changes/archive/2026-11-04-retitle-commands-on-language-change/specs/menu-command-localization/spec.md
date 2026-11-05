## ADDED Requirements

### Requirement: The app's menu commands follow a language change without a relaunch
When the app language changes, the app SHALL re-title its own menu commands at once, without a relaunch. This covers New, Open, Open Recent, Clear Menu, Save, Export To, Close, Print, the zoom commands, the find commands, the Format, Paragraph and Mode menus' own titles, and every command in those menus. A re-titled command SHALL keep its shortcut and its action. Standard AppKit menu items, which are built from the process localization at launch, MAY keep their language until the relaunch that Settings offers.

#### Scenario: The language changes in Settings
- **WHEN** the user chooses Simplified Chinese in Settings and answers the restart prompt with Later
- **THEN** every app-owned command shows its Simplified Chinese title
- **AND** every command keeps its shortcut

#### Scenario: The titles outlast the Settings window
- **WHEN** the language has changed and the user closes Settings
- **THEN** the File menu, opened, shows the commands in the new language

#### Scenario: The language changes back
- **WHEN** the user closes Settings after a change, reopens it with the Settings command, and chooses the previous language
- **THEN** every app-owned command shows its title in that language

#### Scenario: Commands act after a language change
- **WHEN** the language has changed and the user runs New, Find, a Mode command and a Paragraph command
- **THEN** each one acts as it does before the change

#### Scenario: Standard items wait for the relaunch
- **WHEN** the language has changed and the user has not relaunched the app
- **THEN** the restart prompt has been offered for the standard AppKit menu items

### Requirement: The Mode menu shows the configured shortcuts without a relaunch
When the mode shortcuts change, the Mode menu SHALL show the new shortcuts at once, without a relaunch.

#### Scenario: The user resets the mode shortcuts
- **WHEN** custom mode shortcuts are stored and the user presses Reset Shortcuts in Settings
- **THEN** the Mode menu's commands show the default shortcuts
