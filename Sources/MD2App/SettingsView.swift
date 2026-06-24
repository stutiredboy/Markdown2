import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    /// Invoked when the user confirms restarting to apply a language change.
    var onRequestRelaunch: () -> Void = {}

    var body: some View {
        Form {
            Section(settings.text(.general)) {
                Picker(settings.text(.language), selection: $settings.language) {
                    Text(settings.text(.followSystem)).tag(AppLanguage.system)
                    Text(settings.text(.english)).tag(AppLanguage.english)
                    Text(settings.text(.chineseSimplified)).tag(AppLanguage.zhHans)
                }
                .pickerStyle(.menu)

                Picker(settings.text(.defaultOpenMode), selection: $settings.defaultMode) {
                    Text(settings.text(.write)).tag(EditorMode.write)
                    Text(settings.text(.sideBySide)).tag(EditorMode.split)
                    Text(settings.text(.read)).tag(EditorMode.read)
                }
                .pickerStyle(.segmented)

                Picker(settings.text(.newDocumentMode), selection: $settings.newDocumentMode) {
                    Text(settings.text(.write)).tag(EditorMode.write)
                    Text(settings.text(.sideBySide)).tag(EditorMode.split)
                    Text(settings.text(.read)).tag(EditorMode.read)
                }
                .pickerStyle(.segmented)

                Toggle(settings.text(.showOutlineByDefault), isOn: $settings.showsOutlineByDefault)

                Toggle(settings.text(.openBlankOnLaunch), isOn: $settings.opensBlankDocumentOnLaunch)
            }
        }
        .formStyle(.grouped)
        .padding(22)
        .frame(width: 480)
        .navigationTitle(settings.text(.settingsTitle))
        // The standard menu bar is built once at launch from the active
        // localization, so a language change needs a restart to re-localize it.
        .onChange(of: settings.language) { _, _ in
            presentLanguageRestartPrompt()
        }
    }

    /// Asks whether to restart now so the menu bar picks up the new language.
    /// The custom command items already updated live; only the standard AppKit
    /// menus need the relaunch.
    private func presentLanguageRestartPrompt() {
        let alert = NSAlert()
        alert.messageText = settings.text(.languageChangedTitle)
        alert.informativeText = settings.text(.languageChangedMessage)
        alert.addButton(withTitle: settings.text(.restartNow))
        alert.addButton(withTitle: settings.text(.restartLater))
        if alert.runModal() == .alertFirstButtonReturn {
            onRequestRelaunch()
        }
    }
}
