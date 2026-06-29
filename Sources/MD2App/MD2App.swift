import MD2AppSupport
import SwiftUI

@main
struct MD2Application: App {
    @NSApplicationDelegateAdaptor(MD2AppDelegate.self) private var appDelegate

    init() {
        let languageOverrideNeedsRelaunch = AppSettings.storedLanguageOverrideNeedsStartupRelaunch()
        // Apply the stored language to AppleLanguages before AppKit builds the
        // menu (and before any relaunch), so the standard menu bar localizes to
        // the app language rather than the system locale.
        AppSettings.applyStoredLanguageOverride()
        if DirectLaunchBootstrap.relaunchFromAppBundleIfNeeded() {
            exit(EXIT_SUCCESS)
        }
        if DirectLaunchBootstrap.relaunchForLanguageOverrideIfNeeded(languageOverrideNeedsRelaunch) {
            exit(EXIT_SUCCESS)
        }
    }

    var body: some Scene {
        Settings {
            SettingsView(
                settings: appDelegate.settings,
                onRequestRelaunch: { appDelegate.requestLanguageRelaunch() }
            )
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(appDelegate.settings.text(.new)) {
                    appDelegate.newDocument()
                }
                .keyboardShortcut("n")

                Button(appDelegate.settings.text(.open)) {
                    appDelegate.openDocument()
                }
                .keyboardShortcut("o")
            }

            CommandGroup(replacing: .saveItem) {
                Button(appDelegate.settings.text(.save)) {
                    appDelegate.currentDocumentStore?.save()
                }
                .keyboardShortcut("s")

                Menu(appDelegate.settings.text(.exportTo)) {
                    Button("PDF") {
                        appDelegate.currentDocumentStore?.exportPDF()
                    }
                    Button("HTML") {
                        appDelegate.currentDocumentStore?.exportHTML()
                    }
                }

                Divider()

                Button(appDelegate.settings.text(.close)) {
                    appDelegate.closeCurrentDocument()
                }
                .keyboardShortcut("w")
            }

            CommandGroup(replacing: .printItem) {
                Button(appDelegate.settings.text(.print)) {
                    appDelegate.currentDocumentStore?.print()
                }
                .keyboardShortcut("p")
            }

            CommandMenu(appDelegate.settings.text(.mode)) {
                let editShortcut = appDelegate.settings.modeShortcuts[.write]
                Button(appDelegate.settings.text(.write)) {
                    appDelegate.currentDocumentStore?.requestMode(.write)
                }
                .keyboardShortcut(editShortcut.keyEquivalent, modifiers: editShortcut.modifiers.eventModifiers)

                let previewShortcut = appDelegate.settings.modeShortcuts[.read]
                Button(appDelegate.settings.text(.read)) {
                    appDelegate.currentDocumentStore?.requestMode(.read)
                }
                .keyboardShortcut(previewShortcut.keyEquivalent, modifiers: previewShortcut.modifiers.eventModifiers)

                let splitShortcut = appDelegate.settings.modeShortcuts[.split]
                Button(appDelegate.settings.text(.sideBySide)) {
                    appDelegate.currentDocumentStore?.requestMode(.split)
                }
                .keyboardShortcut(splitShortcut.keyEquivalent, modifiers: splitShortcut.modifiers.eventModifiers)
            }

            CommandGroup(after: .textEditing) {
                Divider()
                Button(appDelegate.settings.text(.find)) {
                    appDelegate.currentDocumentStore?.requestFind(.show)
                }
                .keyboardShortcut("f")

                Button(appDelegate.settings.text(.findReplace)) {
                    appDelegate.currentDocumentStore?.requestFind(.showReplace)
                }
                .keyboardShortcut("f", modifiers: [.command, .option])

                Button(appDelegate.settings.text(.findNext)) {
                    appDelegate.currentDocumentStore?.requestFind(.next)
                }
                .keyboardShortcut("g")

                Button(appDelegate.settings.text(.findPrevious)) {
                    appDelegate.currentDocumentStore?.requestFind(.previous)
                }
                .keyboardShortcut("g", modifiers: [.command, .shift])
            }
        }
    }
}
