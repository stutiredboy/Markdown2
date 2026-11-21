import MD2AppSupport
import SwiftUI

/// File ▸ Open Recent. This view must observe `recents` itself: `AppCommands`
/// re-evaluates only when a setting changes, so entries passed in from there
/// would go stale, but a command view's own dependency still updates it. Guarded
/// by RecentDocumentsMenuGUITests.
private struct RecentDocumentsMenu: View {
    let title: String
    let clearTitle: String
    @ObservedObject var recents: RecentDocumentsModel
    let onOpen: (URL) -> Void
    let onClear: () -> Void

    var body: some View {
        Menu(title) {
            ForEach(recents.entries, id: \.url) { entry in
                Button(entry.title) { onOpen(entry.url) }
            }
            if !recents.entries.isEmpty {
                Divider()
            }
            Button(clearTitle, action: onClear)
                .disabled(recents.entries.isEmpty)
        }
    }
}

/// The live list and current folder are dependencies of this command view.
struct FavoriteFoldersMenu: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var favorites: FavoriteFoldersModel
    let onToggleCurrent: () -> Void
    let onOpen: (FavoriteFolderEntry) -> Void
    let onRemove: (FavoriteFolderEntry) -> Void
    let onClear: () -> Void

    var body: some View {
        Menu(settings.text(.favoriteFolders)) {
            if let root = favorites.currentRoot {
                let key: L10nKey = favorites.contains(root) ? .favoriteFolderRemoveCurrent : .favoriteFolderAddCurrent
                Button(settings.text(key), action: onToggleCurrent)
                Divider()
            }
            if favorites.entries.isEmpty {
                Button(settings.text(.favoriteFoldersEmpty)) {}
                    .disabled(true)
            } else {
                ForEach(favorites.entries) { entry in
                    Button(entry.title) { onOpen(entry) }
                        .help(entry.path)
                }
                Divider()
                Menu(settings.text(.favoriteFoldersManage)) {
                    ForEach(favorites.entries) { entry in
                        Button(entry.title) { onRemove(entry) }
                            .help(entry.path)
                    }
                }
            }
            Button(settings.text(.favoriteFoldersClear), action: onClear)
                .disabled(favorites.entries.isEmpty)
        }
    }

    /// SwiftUI maps `help` to the native tooltip. The command bridge does not
    /// propagate accessibility modifiers, so annotate the generated items
    /// when AppKit adds or changes them.
    static func updateNativeAccessibility(_ notification: Notification, settings: AppSettings) {
        guard let menu = notification.object as? NSMenu,
              let index = notification.userInfo?["NSMenuItemIndex"] as? Int,
              let item = menu.item(at: index), !item.isSeparatorItem else { return }

        let favoritesTitle = settings.text(.favoriteFolders)
        let manageTitle = settings.text(.favoriteFoldersManage)
        let identifier: String
        if item.hasSubmenu && item.title == favoritesTitle {
            identifier = "favorite-folders-menu"
        } else if menu.title == favoritesTitle {
            if let path = item.toolTip {
                identifier = "favorite-folders-open-\(path)"
            } else {
                switch item.title {
                case settings.text(.favoriteFolderAddCurrent), settings.text(.favoriteFolderRemoveCurrent):
                    identifier = "favorite-folders-current"
                case settings.text(.favoriteFoldersEmpty):
                    identifier = "favorite-folders-empty"
                case manageTitle:
                    identifier = "favorite-folders-manage"
                case settings.text(.favoriteFoldersClear):
                    identifier = "favorite-folders-clear"
                default: return
                }
            }
        } else if menu.title == manageTitle, let path = item.toolTip {
            identifier = "favorite-folders-remove-\(path)"
        } else {
            return
        }
        item.setAccessibilityIdentifier(identifier)
        item.setAccessibilityLabel(item.title)
        item.setAccessibilityHelp(item.toolTip)
    }
}

/// Observe the key document independently of the Settings scene's command tree.
private struct RemoteImagesCommandMenu: View {
    let settings: AppSettings
    @ObservedObject var state: AttachmentCommandState
    let contentState: (DocumentStore) -> DocumentWindowContentState?

    var body: some View {
        if let document = state.document, let windowState = contentState(document) {
            RemoteResourceNotice(
                document: document, settings: settings, contentState: windowState, placement: .applicationMenu
            )
        }
    }
}

@main
enum Markdown2Main {
    @MainActor static func main() {
        if CommandLine.arguments.dropFirst().elementsEqual([RegexFindProcess.workerArgument]) {
            exit(RegexFindProcess.runChild())
        }
        MD2Application.main()
    }
}

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
        // Document windows are AppKit-managed, so this Settings scene is the
        // app's ONLY SwiftUI scene — and SwiftUI presents an app's only scene at
        // launch when the binary is linked below the macOS 15 SDK (SwiftPM
        // records the deployment target as the SDK version, which is how the
        // pre-floor builds got there). Without this the Settings window opens by
        // itself on every launch, including Finder opens, which launch the app.
        //
        // Kept even though the macOS 15 floor also makes the binary "linked on
        // 15": it states the intent independently of the linkage, and it is what
        // keeps the window from coming back if the floor is ever lowered.
        // Guarded by SettingsWindowPresentationGUITests.
        .defaultLaunchBehavior(.suppressed)
        .commands {
            AppCommands(settings: appDelegate.settings, appDelegate: appDelegate)
        }
    }
}

/// The app's own menu commands. This must stay a `Commands` type that observes
/// `settings` itself: the App body and its `.commands` closure run once, at
/// launch, so anything read there keeps its launch value, and a view inside a menu
/// could not reach the titles of the Format, Paragraph and Mode menus. Standard
/// AppKit items (the File and Edit menus' own titles, Undo, Copy, …) are built from
/// the process localization and still need the relaunch that Settings offers.
/// Guarded by MenuLanguageGUITests.
private struct AppCommands: Commands {
    @ObservedObject var settings: AppSettings
    let appDelegate: MD2AppDelegate

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button(settings.text(.new)) {
                appDelegate.newDocument()
            }
            .keyboardShortcut("n")

            Button(settings.text(.open)) {
                appDelegate.openDocument()
            }
            .keyboardShortcut("o")

            RecentDocumentsMenu(
                title: settings.text(.openRecent),
                clearTitle: settings.text(.clearMenu),
                recents: appDelegate.recentDocuments,
                onOpen: { appDelegate.openRecentDocument($0) },
                onClear: { appDelegate.clearRecentDocuments() }
            )

            Button(settings.text(.openFolder)) {
                appDelegate.openFolder()
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])

            Button(settings.text(.folderQuickOpen)) {
                appDelegate.quickOpenFolderFile()
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])

            Button(settings.text(.focusFolderBrowser)) {
                appDelegate.focusFolderBrowser()
            }
            .keyboardShortcut(settings.folderBrowserShortcut.keyEquivalent,
                              modifiers: settings.folderBrowserShortcut.modifiers.eventModifiers)

            Button(settings.text(.revealInFolderBrowser)) {
                appDelegate.revealInFolderBrowser()
            }

            FavoriteFoldersMenu(
                settings: settings,
                favorites: appDelegate.favoriteFolders,
                onToggleCurrent: { appDelegate.toggleCurrentFavoriteFolder() },
                onOpen: { appDelegate.openFavoriteFolder($0) },
                onRemove: { appDelegate.removeFavoriteFolder($0) },
                onClear: { appDelegate.clearFavoriteFolders() }
            )
        }

        CommandGroup(replacing: .saveItem) {
            Button(settings.text(.save)) {
                appDelegate.currentDocumentStore?.save()
            }
            .keyboardShortcut("s")

            Button(settings.text(.createCopy)) {
                appDelegate.createCopy()
            }

            Button(settings.text(.historyBrowse)) {
                appDelegate.browseLocalHistory()
            }

            CollectLocalImagesCommand(title: settings.text(.collectLocalImages), state: appDelegate.attachmentCommandState) {
                guard let document = appDelegate.currentDocumentStore, !document.isWorkingOnAttachments else { return }
                Task { await document.collectLocalImages(folder: settings.attachmentFolder) }
            }

            Menu(settings.text(.exportTo)) {
                Button("PDF") {
                    Task { await appDelegate.currentDocumentStore?.exportPDF() }
                }
                Button("HTML") {
                    Task { await appDelegate.currentDocumentStore?.exportHTML() }
                }
                Button("DOCX") {
                    appDelegate.currentDocumentStore?.exportDOCX()
                }
                Button("EPUB") {
                    appDelegate.currentDocumentStore?.exportEPUB()
                }
            }

            Divider()

            Button(settings.text(.close)) {
                appDelegate.closeCurrentDocument()
            }
            .keyboardShortcut("w")
        }

        CommandGroup(replacing: .printItem) {
            Button(settings.text(.print)) {
                Task { await appDelegate.currentDocumentStore?.print() }
            }
            .keyboardShortcut("p")
        }

        CommandMenu(settings.text(.formatMenu)) {
            ForEach(MarkdownFormatCommand.formatItems, id: \.title) { item in
                Button(settings.text(item.title)) {
                    appDelegate.currentDocumentStore?.requestFormat(item.action)
                }
                .keyboardShortcut(item.shortcut.keyEquivalent, modifiers: item.shortcut.modifiers.eventModifiers)
            }
            Menu(settings.text(.tableOperations)) {
                ForEach(MarkdownFormatCommand.tableItems, id: \.title) { item in
                    TableEditingCommand(title: settings.text(item.title), state: appDelegate.attachmentCommandState) {
                        appDelegate.currentDocumentStore?.requestTableEdit(item.action)
                    }
                }
            }
        }

        CommandMenu(settings.text(.paragraphMenu)) {
            ForEach(MarkdownFormatCommand.paragraphItems, id: \.title) { item in
                Button(settings.text(item.title)) {
                    appDelegate.currentDocumentStore?.requestFormat(item.action)
                }
                .keyboardShortcut(item.shortcut.keyEquivalent, modifiers: item.shortcut.modifiers.eventModifiers)
            }
        }

        CommandGroup(after: .toolbar) {
            Button(settings.text(.zoomIn), action: settings.zoomIn)
                .keyboardShortcut("+", modifiers: .command)
            // Also accept the unshifted = key on keyboards where + is Shift-=.
            Button(settings.text(.zoomIn), action: settings.zoomIn)
                .keyboardShortcut("=", modifiers: .command)
                .hidden()
            Button(settings.text(.zoomOut), action: settings.zoomOut)
                .keyboardShortcut("-", modifiers: .command)
            Button(settings.text(.resetZoom), action: settings.resetZoom)
                .keyboardShortcut("0", modifiers: [.command, .option])

            RemoteImagesCommandMenu(
                settings: settings, state: appDelegate.attachmentCommandState,
                contentState: appDelegate.contentState(for:)
            )
        }

        CommandMenu(settings.text(.mode)) {
            let editShortcut = settings.modeShortcuts[.write]
            Button(settings.text(.write)) {
                appDelegate.currentDocumentStore?.requestMode(.write)
            }
            .keyboardShortcut(editShortcut.keyEquivalent, modifiers: editShortcut.modifiers.eventModifiers)

            let previewShortcut = settings.modeShortcuts[.read]
            Button(settings.text(.read)) {
                appDelegate.currentDocumentStore?.requestMode(.read)
            }
            .keyboardShortcut(previewShortcut.keyEquivalent, modifiers: previewShortcut.modifiers.eventModifiers)

            let splitShortcut = settings.modeShortcuts[.split]
            Button(settings.text(.sideBySide)) {
                appDelegate.currentDocumentStore?.requestMode(.split)
            }
            .keyboardShortcut(splitShortcut.keyEquivalent, modifiers: splitShortcut.modifiers.eventModifiers)

            Divider()
            Toggle(settings.text(.typewriterScrolling), isOn: $settings.usesTypewriterScrolling)
        }

        CommandGroup(after: .pasteboard) {
            MarkdownPasteCommandButtons(state: appDelegate.pasteCommandState, settings: settings)
        }

        CommandGroup(after: .textEditing) {
            Divider()
            Button(settings.text(.find)) {
                appDelegate.currentDocumentStore?.requestFind(.show)
            }
            .keyboardShortcut("f")

            Button(settings.text(.findReplace)) {
                appDelegate.currentDocumentStore?.requestFind(.showReplace)
            }
            .keyboardShortcut("f", modifiers: [.command, .option])

            Button(settings.text(.findNext)) {
                appDelegate.currentDocumentStore?.requestFind(.next)
            }
            .keyboardShortcut("g")

            Button(settings.text(.findPrevious)) {
                appDelegate.currentDocumentStore?.requestFind(.previous)
            }
            .keyboardShortcut("g", modifiers: [.command, .shift])
        }
    }
}
