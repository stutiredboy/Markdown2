import MD2AppSupport
import SwiftUI

@main
struct MD2Application: App {
    @NSApplicationDelegateAdaptor(MD2AppDelegate.self) private var appDelegate

    init() {
        if DirectLaunchBootstrap.relaunchFromAppBundleIfNeeded() {
            exit(EXIT_SUCCESS)
        }
    }

    var body: some Scene {
        Settings {
            SettingsView(settings: appDelegate.settings)
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

                Button(appDelegate.settings.text(.saveAs)) {
                    appDelegate.currentDocumentStore?.saveAs()
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])

                Button(appDelegate.settings.text(.exportPDF)) {
                    appDelegate.currentDocumentStore?.exportPDF()
                }

                Divider()

                Button(appDelegate.settings.text(.close)) {
                    appDelegate.closeCurrentDocument()
                }
                .keyboardShortcut("w")
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
