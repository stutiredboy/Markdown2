import Foundation
import MD2Core

@MainActor
final class AppSettings: ObservableObject {
    @Published var typography: TypographySettings {
        didSet {
            if typography != typography.normalized { typography = typography.normalized }
            guard let data = try? JSONEncoder().encode(typography) else { return }
            defaults.set(data, forKey: Keys.typography)
        }
    }

    func zoomIn() { typography.zoom = min(2, (typography.zoom * 10).rounded() / 10 + 0.1) }
    func zoomOut() { typography.zoom = max(0.5, (typography.zoom * 10).rounded() / 10 - 0.1) }
    func resetZoom() { typography.zoom = 1 }

    @Published var language: AppLanguage {
        didSet {
            defaults.set(language.rawValue, forKey: Keys.language)
            Self.applyLanguageOverride(language, defaults: defaults)
        }
    }

    /// Mode applied to documents opened from a file (file argument, Open panel,
    /// Finder). New/blank documents use `newDocumentMode` instead.
    @Published var defaultMode: EditorMode {
        didSet {
            defaults.set(defaultMode.rawValue, forKey: Keys.defaultMode)
        }
    }

    /// Mode applied to new/blank documents (direct launch, New, reopen with no
    /// windows). Defaults to Edit so launching the app lands on a writable surface.
    @Published var newDocumentMode: EditorMode {
        didSet {
            defaults.set(newDocumentMode.rawValue, forKey: Keys.newDocumentMode)
        }
    }

    @Published var preferTabsForDocuments: Bool {
        didSet { defaults.set(preferTabsForDocuments, forKey: Keys.preferTabsForDocuments) }
    }

    @Published private(set) var modeShortcuts: ModeShortcutConfiguration {
        didSet {
            guard let data = try? JSONEncoder().encode(modeShortcuts) else { return }
            defaults.set(data, forKey: Keys.modeShortcuts)
        }
    }

    @Published var usesTypewriterScrolling: Bool {
        didSet { defaults.set(usesTypewriterScrolling, forKey: Keys.usesTypewriterScrolling) }
    }

    @Published var showsOutlineByDefault: Bool {
        didSet {
            defaults.set(showsOutlineByDefault, forKey: Keys.showsOutlineByDefault)
        }
    }

    /// Whether launching the app directly (no file to open) creates a blank
    /// starter document. Defaults to off so a plain launch opens nothing; the
    /// user can still create one with New or open a file.
    @Published var opensBlankDocumentOnLaunch: Bool {
        didSet {
            defaults.set(opensBlankDocumentOnLaunch, forKey: Keys.opensBlankDocumentOnLaunch)
        }
    }

    @Published var restoresWindowsOnLaunch: Bool {
        didSet { defaults.set(restoresWindowsOnLaunch, forKey: Keys.restoresWindowsOnLaunch) }
    }

    @Published var keepsLocalHistory: Bool {
        didSet { defaults.set(keepsLocalHistory, forKey: Keys.keepsLocalHistory) }
    }

    /// Whether the editor draws a source line-number gutter in its left inset.
    /// Toggling it never changes the text, selection, or any geometry; while it
    /// is on, clicking a number selects that line.
    @Published var showsLineNumbersInEditor: Bool {
        didSet {
            defaults.set(showsLineNumbersInEditor, forKey: Keys.showsLineNumbersInEditor)
        }
    }

    /// Whether the preview shows the starting source line beside each rendered
    /// block. Independent of `showsLineNumbersInEditor`, so both surfaces can be
    /// on at once (and Side by Side shows each pane per its own preference).
    @Published var showsLineNumbersInPreview: Bool {
        didSet {
            defaults.set(showsLineNumbersInPreview, forKey: Keys.showsLineNumbersInPreview)
        }
    }

    /// Copying makes future file insertions document-relative; explicit linking
    /// retains the original location. This never migrates existing references.
    @Published var imageFileHandling: ImageFileHandling {
        didSet { defaults.set(imageFileHandling.rawValue, forKey: Keys.imageFileHandling) }
    }

    /// Relative folder for copied image files and clipboard screenshots.
    @Published var attachmentFolder: String {
        didSet {
            defaults.set(attachmentFolder, forKey: Keys.attachmentFolder)
        }
    }

    /// Page geometry and running-text settings applied to PDF export and Print.
    /// Persisted as a JSON blob so the whole profile round-trips in one key. The
    /// default reproduces the app's previous fixed output (A4 portrait, narrow
    /// margins, no page numbers or headers/footers).
    @Published var exportProfile: ExportProfile {
        didSet {
            guard let data = try? JSONEncoder().encode(exportProfile) else { return }
            defaults.set(data, forKey: Keys.exportProfile)
        }
    }

    /// How inline citations render in the preview (author-year or numeric). The
    /// renderer reads this through the document store's render config.
    @Published var citationStyle: CitationStyle {
        didSet {
            defaults.set(citationStyle.rawValue, forKey: Keys.citationStyle)
        }
    }

    /// Whether every display equation is numbered, or only those with a `\label{}`.
    @Published var numberAllEquations: Bool {
        didSet {
            defaults.set(numberAllEquations, forKey: Keys.numberAllEquations)
        }
    }

    @Published var enablesHighlight: Bool {
        didSet { defaults.set(enablesHighlight, forKey: Keys.enablesHighlight) }
    }
    @Published var enablesSuperscript: Bool {
        didSet { defaults.set(enablesSuperscript, forKey: Keys.enablesSuperscript) }
    }
    @Published var enablesSubscript: Bool {
        didSet { defaults.set(enablesSubscript, forKey: Keys.enablesSubscript) }
    }

    var inlineFeatures: InlineFeatures {
        InlineFeatures(highlight: enablesHighlight, superscript: enablesSuperscript, subscriptEnabled: enablesSubscript)
    }

    var alertLanguage: AlertLanguage {
        effectiveLanguage == .zhHans ? .simplifiedChinese : .english
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        typography = defaults.data(forKey: Keys.typography)
            .flatMap { try? JSONDecoder().decode(TypographySettings.self, from: $0) }?.normalized ?? TypographySettings()
        enablesHighlight = defaults.bool(forKey: Keys.enablesHighlight)
        enablesSuperscript = defaults.bool(forKey: Keys.enablesSuperscript)
        enablesSubscript = defaults.bool(forKey: Keys.enablesSubscript)

        let languageValue = defaults.string(forKey: Keys.language) ?? AppLanguage.system.rawValue
        language = AppLanguage(rawValue: languageValue) ?? .system

        let modeValue = defaults.string(forKey: Keys.defaultMode) ?? EditorMode.write.rawValue
        defaultMode = EditorMode(rawValue: modeValue) ?? .write

        let newModeValue = defaults.string(forKey: Keys.newDocumentMode) ?? EditorMode.write.rawValue
        newDocumentMode = EditorMode(rawValue: newModeValue) ?? .write

        preferTabsForDocuments = defaults.object(forKey: Keys.preferTabsForDocuments) == nil
            || defaults.bool(forKey: Keys.preferTabsForDocuments)

        if let data = defaults.data(forKey: Keys.modeShortcuts),
           let decoded = try? JSONDecoder().decode(ModeShortcutConfiguration.self, from: data),
           ModeShortcutValidator.isValidConfiguration(decoded) {
            modeShortcuts = decoded
        } else {
            modeShortcuts = .default
        }
        usesTypewriterScrolling = defaults.bool(forKey: Keys.usesTypewriterScrolling)

        if defaults.object(forKey: Keys.showsOutlineByDefault) == nil {
            showsOutlineByDefault = true
        } else {
            showsOutlineByDefault = defaults.bool(forKey: Keys.showsOutlineByDefault)
        }

        if defaults.object(forKey: Keys.opensBlankDocumentOnLaunch) == nil {
            opensBlankDocumentOnLaunch = false
        } else {
            opensBlankDocumentOnLaunch = defaults.bool(forKey: Keys.opensBlankDocumentOnLaunch)
        }
        if defaults.object(forKey: Keys.restoresWindowsOnLaunch) == nil {
            let systemValue = (defaults.object(forKey: "NSQuitAlwaysKeepsWindows") as? NSNumber)?.boolValue
                ?? (defaults.persistentDomain(forName: UserDefaults.globalDomain)?["NSQuitAlwaysKeepsWindows"] as? NSNumber)?.boolValue
            restoresWindowsOnLaunch = systemValue ?? true
        } else {
            restoresWindowsOnLaunch = defaults.bool(forKey: Keys.restoresWindowsOnLaunch)
        }
        keepsLocalHistory = defaults.object(forKey: Keys.keepsLocalHistory) as? Bool ?? true

        if defaults.object(forKey: Keys.showsLineNumbersInEditor) == nil {
            showsLineNumbersInEditor = false
        } else {
            showsLineNumbersInEditor = defaults.bool(forKey: Keys.showsLineNumbersInEditor)
        }

        if defaults.object(forKey: Keys.showsLineNumbersInPreview) == nil {
            showsLineNumbersInPreview = false
        } else {
            showsLineNumbersInPreview = defaults.bool(forKey: Keys.showsLineNumbersInPreview)
        }

        imageFileHandling = defaults.string(forKey: Keys.imageFileHandling).flatMap(ImageFileHandling.init(rawValue:)) ?? .copy
        let storedFolder = defaults.string(forKey: Keys.attachmentFolder)
        attachmentFolder = (storedFolder?.isEmpty == false) ? storedFolder! : "assets"

        if let data = defaults.data(forKey: Keys.exportProfile),
           let decoded = try? JSONDecoder().decode(ExportProfile.self, from: data) {
            exportProfile = decoded
        } else {
            exportProfile = .default
        }

        let citationValue = defaults.string(forKey: Keys.citationStyle) ?? CitationStyle.authorYear.rawValue
        citationStyle = CitationStyle(rawValue: citationValue) ?? .authorYear

        if defaults.object(forKey: Keys.numberAllEquations) == nil {
            numberAllEquations = false
        } else {
            numberAllEquations = defaults.bool(forKey: Keys.numberAllEquations)
        }
    }

    /// Applies the stored language preference to the process's `AppleLanguages`
    /// override so AppKit localizes the *standard* menu bar (File/Edit/View/…
    /// and system items) to match the app language, independent of the system
    /// locale. Reads `UserDefaults` directly (no `AppSettings` instance) so it
    /// can run at the very start of `init()` before the menu is built. A stored
    /// `.system` removes the override so the process follows the system locale.
    static func applyStoredLanguageOverride(defaults: UserDefaults = .standard) {
        applyLanguageOverride(storedLanguage(defaults: defaults), defaults: defaults)
    }

    /// Returns true when the app-domain `AppleLanguages` override differs from
    /// the stored language preference. Used at startup to decide whether the app
    /// needs one guarded relaunch: AppKit reads process localization before
    /// `App.init`, so an override written for the first time in `init()` cannot
    /// affect the current process's already-selected standard menu localizations.
    static func storedLanguageOverrideNeedsStartupRelaunch(defaults: UserDefaults = .standard) -> Bool {
        appDomainAppleLanguagesOverride(defaults: defaults) != storedLanguage(defaults: defaults).appleLanguagesOverride
    }

    /// The `UserDefaults` key AppKit reads to pick the app's localization.
    static let appleLanguagesKey = "AppleLanguages"

    private static func storedLanguage(defaults: UserDefaults) -> AppLanguage {
        let raw = defaults.string(forKey: Keys.language) ?? AppLanguage.system.rawValue
        return AppLanguage(rawValue: raw) ?? .system
    }

    private static func applyLanguageOverride(_ language: AppLanguage, defaults: UserDefaults) {
        if let override = language.appleLanguagesOverride {
            defaults.set(override, forKey: appleLanguagesKey)
        } else {
            defaults.removeObject(forKey: appleLanguagesKey)
        }
    }

    private static func appDomainAppleLanguagesOverride(defaults: UserDefaults) -> [String]? {
        if defaults === UserDefaults.standard,
           let bundleIdentifier = Bundle.main.bundleIdentifier {
            return defaults.persistentDomain(forName: bundleIdentifier)?[appleLanguagesKey] as? [String]
        }
        return defaults.object(forKey: appleLanguagesKey) as? [String]
    }

    /// Resolves the initial editor mode for a document from whether it is backed
    /// by a file: opened files follow `defaultMode`, new/blank documents follow
    /// `newDocumentMode`.
    func presentationMode(isFileBacked: Bool) -> EditorMode {
        isFileBacked ? defaultMode : newDocumentMode
    }

    func updateModeShortcut(
        _ shortcut: ModeKeyboardShortcut,
        for mode: EditorMode
    ) -> ModeShortcutValidationError? {
        var next = modeShortcuts
        next[mode] = shortcut
        if let error = ModeShortcutValidator.validate(shortcut, for: mode, in: next) {
            return error
        }
        modeShortcuts = next
        return nil
    }

    func resetModeShortcutsToDefaults() {
        modeShortcuts = .default
    }

    var effectiveLanguage: AppLanguage {
        if language != .system {
            return language
        }

        let preferred = Locale.preferredLanguages.first?.lowercased() ?? ""
        return preferred.hasPrefix("zh") ? .zhHans : .english
    }

    func text(_ key: L10nKey) -> String {
        L10n.text(key, language: effectiveLanguage)
    }

    func modeLabel(_ mode: EditorMode) -> String {
        switch mode {
        case .write:
            text(.write)
        case .read:
            text(.read)
        case .split:
            text(.sideBySide)
        }
    }

    var folderBrowserShortcut: ModeKeyboardShortcut {
        // Preserve shortcuts customized in earlier releases. There are four
        // candidates and at most three mode assignments.
        let modifiers: [ModeShortcutModifiers] = [
            [.command, .shift], [.command, .option, .shift],
            [.command, .control, .shift], [.command, .option, .control, .shift]
        ]
        let assigned = Set(modeShortcuts.assignments.map(\.shortcut))
        return modifiers.map { ModeKeyboardShortcut(key: "b", modifiers: $0) }
            .first { !assigned.contains($0) } ?? ModeKeyboardShortcut(key: "b", modifiers: [.command, .shift])
    }

    var modePickerHelp: String {
        String(
            format: text(.modePickerHelp),
            modeShortcuts[.write].symbolDisplayString,
            modeShortcuts[.split].symbolDisplayString,
            modeShortcuts[.read].symbolDisplayString
        )
    }

    func modeShortcutValidationMessage(_ error: ModeShortcutValidationError) -> String {
        switch error {
        case .malformed:
            text(.shortcutMalformed)
        case let .duplicate(existingMode):
            String(format: text(.shortcutDuplicate), modeLabel(existingMode))
        case let .appCommand(commandName):
            String(format: text(.shortcutAppCommandConflict), commandName)
        case let .systemReserved(reason):
            String(format: text(.shortcutSystemConflict), reason)
        }
    }
}

private enum Keys {
    static let typography = "MD2.Typography"
    static let enablesHighlight = "MD2.EnablesHighlight"
    static let enablesSuperscript = "MD2.EnablesSuperscript"
    static let enablesSubscript = "MD2.EnablesSubscript"
    static let language = "MD2.Language"
    static let defaultMode = "MD2.DefaultMode"
    static let newDocumentMode = "MD2.NewDocumentMode"
    static let preferTabsForDocuments = "MD2.PreferTabsForDocuments"
    static let modeShortcuts = "MD2.ModeShortcuts"
    static let usesTypewriterScrolling = "MD2.UsesTypewriterScrolling"
    static let showsOutlineByDefault = "MD2.ShowsOutlineByDefault"
    static let opensBlankDocumentOnLaunch = "MD2.OpensBlankDocumentOnLaunch"
    static let restoresWindowsOnLaunch = "MD2.RestoresWindowsOnLaunch"
    static let keepsLocalHistory = "MD2.KeepsLocalHistory"
    static let showsLineNumbersInEditor = "MD2.ShowsLineNumbersInEditor"
    static let showsLineNumbersInPreview = "MD2.ShowsLineNumbersInPreview"
    static let imageFileHandling = "MD2.ImageFileHandling"
    static let attachmentFolder = "MD2.AttachmentFolder"
    static let exportProfile = "MD2.ExportProfile"
    static let citationStyle = "MD2.CitationStyle"
    static let numberAllEquations = "MD2.NumberAllEquations"
}

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case english
    case zhHans

    var id: String {
        rawValue
    }

    /// `AppleLanguages` override codes for this *stored* language, or `nil` for
    /// `.system` (no override → follow the system locale). Resolved from the raw
    /// stored value, never from `effectiveLanguage`, so `.system` stays `nil`.
    var appleLanguagesOverride: [String]? {
        switch self {
        case .system:
            nil
        case .english:
            ["en"]
        case .zhHans:
            ["zh-Hans"]
        }
    }
}

enum L10nKey: String, CaseIterable, Sendable {
    case typography, editorFont, readingFont, fontSize, readingWidth, readingWidthHelp, zoomIn, zoomOut, resetZoom, zoom
    case fontSystem, fontSerif, fontMonospaced, readingNarrow, readingComfortable, readingWide, readingFull
    case selectionStats
    case new
    case open
    case openFolder, folderQuickOpen, folderAuthorizationFailed, folderSaveUnavailable
    case folderSidebarFiles, showSidebar, hideSidebar, focusFolderBrowser, revealInFolderBrowser, folderPreviewTabHelp
    case favoriteFolders, favoriteFoldersEmpty, favoriteFoldersManage, favoriteFoldersClear
    case favoriteFolderAddCurrent, favoriteFolderRemoveCurrent, favoriteFolderRemove, favoriteFolderKeep
    case favoriteFolderUnavailable, favoriteFolderMoved, favoriteFolderPermissionDenied, favoriteFolderLink
    case favoriteFolderCannotAdd, favoriteFolderAdded, favoriteFolderRemoved, favoriteFoldersCleared
    case openRecent
    case clearMenu
    case recentDocumentMissingDetail
    case save
    case createCopy, createCopyAction, copyPromptDetail, copyNameSuffix, copyFilename
    case copyCreated, copyCreatedDetail, openCopy, dismissCopyNotice, copyFailed
    case copySaveFirst, copyFinishComposition, copySourceChanged, copyInvalidName
    case copySourceUnavailable, copyNameExists, copyEncodingUnavailable, copyOpenFailed, copySaveUnavailable
    case historyBrowse, historyTitle, historyDisabled, historySaveFirst, historySourceChanged, historyLoadFailed
    case historyRevisionUnavailable, historySomeUnavailable, historyCopyFailed, historyCopyOpenFailed, historyEmpty
    case historyRevisionOpened, historyRevisionSaved, historyRevisionExternal
    case historyExcerpt, historyEmptyExcerpt, historySelectRevision, historyLoading, historyRestoring
    case historyAttachments, historyRestoreAsCopy, historyRestoreAndOpen, historyCopyNameSuffix
    case historyEnabledSetting, historySettingDetail, historyClear, historyClearConfirm, historyClearAction, historyClearFailed
    case exportTo
    case exportPDF
    case exportHTML
    case exportDOCX
    case exportEPUB
    case close
    case folderQuickOpenField, folderFilterPlaceholder, folderFileList, folderLandingPrompt
    case folderRefresh, folderCancelScan, folderOpenSelection, folderScanning, folderOpening
    case folderNoFiles, folderOneFile, folderFileCount, folderOneMatch, folderMatchCount
    case folderScanLimited, folderScanUnreadable, folderScanCancelled, folderRefreshCancelled
    case folderRootUnavailable, folderFileUnavailable, folderFileTooLarge
    case outline
    case noHeadings
    case hideOutline
    case showOutline
    case showMetadata
    case hideMetadata
    case navigateToHeading
    case mode
    case write
    case markdownSource
    case read
    case sideBySide
    case writeOrRead
    case modePickerHelp
    case formulaEditButton, formulaEditorTitle, formulaEditorInstructions, formulaEditorInput, formulaApply
    case formulaRevealButton, formulaSourceTitle, formulaSourceDetail, formulaOpenSource
    case formulaEditUnavailable, formulaEditUnavailableDetail, formulaCheckingDraft, formulaReplacementRequiresSource
    case typewriterScrolling
    case words
    case chars
    case lines
    case minRead
    case ok
    case settingsTitle
    case language
    case followSystem
    case english
    case chineseSimplified
    case defaultOpenMode
    case newDocumentMode
    case preferTabsForDocuments
    case modeShortcuts
    case resetModeShortcuts
    case clickToRecordShortcut
    case recordingShortcut
    case shortcutMalformed
    case shortcutDuplicate
    case shortcutAppCommandConflict
    case shortcutSystemConflict
    case showOutlineByDefault
    case general
    case preferences
    case unsavedChangesTitle
    case unsavedChangesMessage
    case externalChangeConflictTitle
    case externalChangeConflictMessage
    case keepMyVersion
    case reloadFromDisk
    case linkedSaveInterruptedTitle, linkedSaveInterruptedMessage, finishLinkedSave, linkedSaveLater
    case cancel
    case dontSave
    case alertCouldNotOpen
    case alertHeadingNotFound, alertHeadingNotFoundDetail
    case alertUndecodableFile
    case alertUndecodableFileDetail
    case alertCouldNotSave, alertUnverifiedSaveDestination, alertRecoveryRequiredForLinkedSave
    case alertRecoveryFailed, alertRecoveryUnreadable
    case encodingConversionTitle, encodingConversionMessage, convertToUTF8
    case mixedLineEndings
    case alertCouldNotExport
    case alertHTMLExportIncomplete, alertHTMLExportRemoteImages, alertHTMLExportLocalImages, alertHTMLExportMoreImages
    case alertHTMLExported, alertHTMLExportDiagramResources
    case alertCouldNotPrint
    case alertPandocRequired
    case alertPandocRequiredDetail
    case conversionDestinationTitle, conversionDestinationNotice, exportConversionProgress
    case alertExportSourceDestination, alertConversionSourceChanged
    case conversionPreparationFailed, conversionFailed, conversionFailedWithDetail
    case conversionDestinationChanged, conversionConfinementUnavailable, conversionCanceled, conversionTimedOut
    case alertHTMLExportInvalidImage, alertHTMLExportImageLimit
    case alertExternalAttachmentDirectory, alertExternalAttachmentDirectoryDetail, useAttachmentFolder
    case alertAttachmentSaveFailed
    case alertExternalReloadFailedDetail
    case formatMenu, paragraphMenu
    case formatBold, formatItalic, formatLink, formatCodeBlock, formatTable, formatBody
    case tableOperations, tableInsertRowAbove, tableInsertRowBelow, tableDeleteRow
    case tableInsertColumnBefore, tableInsertColumnAfter, tableDeleteColumn
    case tableUnsupported, tableSelectCell, tableKeepHeader, tableKeepColumn, tableLimitReached
    case formatHeading1, formatHeading2, formatHeading3, formatHeading4, formatHeading5, formatHeading6
    case find
    case findNext
    case findPrevious
    case findReplace
    case findPlaceholder
    case replaceWith
    case replace
    case replaceAll
    case formattingTargetNotice
    case pasteAsPlainText, pasteAsMarkdown, pasteAsTable
    case pasteLiteralFallbackNotice, pasteUnavailableNotice, pasteLimitNotice, pasteCancelledNotice, pasteUnsafeContextNotice
    case findMatchCase
    case findWholeWord
    case findRegex, findRegexHelp, findRegexWholeWordHelp, findRegexReplacementHelp
    case findRegexSearching, findRegexPreparingReplacement, findRegexInvalidPattern, findRegexSearchLimit
    case findRegexInvalidReplacement, findRegexReplacementLimit, findRegexSearchFailed, findRegexMatchCount
    case findOnlySelection
    case findSourceSelection
    case findWholeDocument
    case findSelectionInvalid
    case findSelectionFrozen
    case findUseSelection
    case findSourceOnlyHelp
    case findScopeCount
    case findReplacementCancelled
    case findReplacedCount
    case findPreviewUnavailable
    case closeFind
    case matchStatus
    case noResults
    case print
    case openBlankOnLaunch
    case restoreWindowsOnLaunch, recoveryInterruptedTitle, recoveryInterruptedMessage, skipRecovery, restoreRecovery
    case unsavedRecoveryTitle, unsavedRecoveryMessage, recoverDrafts
    case languageChangedTitle
    case languageChangedMessage
    case restartNow
    case restartLater
    case collectLocalImages
    case imageFileHandling
    case imageFileCopy
    case imageFileLink
    case attachmentReport
    case attachmentWrittenCount
    case attachmentReferenceCount
    case attachmentStale
    case attachmentCollectionScope
    case attachmentUnsupportedSyntax
    case attachmentExcludedBlocks
    case attachmentNonlocal
    case attachmentInvalidImage
    case attachmentResourceLimit
    case attachmentReadWriteFailed
    case attachmentDestinationChanged
    case attachmentScanLimit
    case attachmentExternalNotPortable
    case attachmentFolder
    case attachmentFolderHelp
    case imageNotFound
    case remoteImageUnavailable
    case remoteImages, remoteImagesBlocked, remoteImagesAllowed, remoteImagesAllow, remoteImagesAllowConfirm, remoteImagesRevoke
    case remoteImagesExplanation, remoteImagesPrivacy, remoteImagesAllowedExplanation, remoteImagesPreparing
    case remoteImagesDetails, remoteImagesDetailsTitle, remoteImagesOrigins, remoteImagesOriginCount
    case remoteImagesDetailsScope, remoteImagesDetailsOtherBlocked, remoteImagesDetailsUnknown, remoteImagesDetailsInspecting
    case remoteImagesNoReferences, remoteImagesDetailsPartial
    case remoteImagesPermissions, remoteImagesFolderPermissions
    case remoteImagesFolderAllow, remoteImagesFolderRevoke, remoteImagesFolderConfirmTitle, remoteImagesFolderExplanation
    case remoteImagesFolderSession, remoteImagesFolderCanFavorite, remoteImagesFolderFavorite
    case remoteImagesAllowedByFolder, remoteImagesAllowedByDocument, remoteImagesBlockedByDocument
    case remoteImagesBlockDocument, remoteImagesUseFolderPermission
    case remoteImageBlocked, offlineHTMLRemoteImageBlocked, offlineHTMLLocalImageUnavailable
    case alertExternalFormatExported, alertExternalFormatNetworkBoundary
    case imageLoadFailed
    case exportSettings
    case pageSizeLabel
    case orientationLabel
    case orientationPortrait
    case orientationLandscape
    case marginsLabel
    case marginNone
    case marginNarrow
    case marginNormal
    case marginWide
    case marginCustom
    case marginTop
    case marginLeft
    case marginBottom
    case marginRight
    case pageNumbers
    case pageNumberPosition
    case pageHeader
    case pageFooter
    case zoneLeft
    case zoneCenter
    case zoneRight
    case runningTextTokensHelp
    case academic
    case markdownSyntax
    case enablesHighlight
    case enablesSuperscript
    case enablesSubscript, subscriptHelp
    case citationStyleLabel
    case citationAuthorYear
    case citationNumeric
    case numberAllEquations
    case academicHelp
    case lineNumbers
    case lineNumbersInEditor
    case lineNumbersInPreview
    case lineNumbersHelp
}

enum L10n {
    static func text(_ key: L10nKey, language: AppLanguage) -> String {
        switch language {
        case .zhHans:
            zhHans[key] ?? english[key] ?? key.rawValue
        case .system, .english:
            english[key] ?? key.rawValue
        }
    }

    /// Whether `key` has an entry in `language`'s dictionary. The two tables are
    /// authored by hand and `text` falls back silently
    /// (`zhHans[key] ?? english[key] ?? key.rawValue`), so a missing entry ships
    /// as English — or a raw enum string — to users of that language. Exposing
    /// the check keeps the completeness test able to guard every key, including
    /// ones added later.
    static func hasTranslation(_ key: L10nKey, language: AppLanguage) -> Bool {
        switch language {
        case .zhHans:
            zhHans[key] != nil
        case .system, .english:
            english[key] != nil
        }
    }

    private static let english: [L10nKey: String] = [
        .typography: "Typography", .editorFont: "Editor Font", .readingFont: "Reading Font",
        .fontSize: "Base Font Size", .readingWidth: "Reading Width", .zoom: "Zoom",
        .readingWidthHelp: "Change the width of the preview’s reading column.",
        .zoomIn: "Zoom In", .zoomOut: "Zoom Out", .resetZoom: "Actual Size",
        .fontSystem: "System", .fontSerif: "Serif", .fontMonospaced: "Monospaced",
        .readingNarrow: "Narrow", .readingComfortable: "Comfortable", .readingWide: "Wide", .readingFull: "Full Width",
        .selectionStats: "Selection",
        .new: "New",
        .open: "Open...",
        .openFolder: "Open Folder…",
        .folderQuickOpen: "Quick Open…",
        .folderSidebarFiles: "Files",
        .showSidebar: "Show Sidebar",
        .hideSidebar: "Hide Sidebar",
        .focusFolderBrowser: "Focus Folder Browser",
        .revealInFolderBrowser: "Reveal in Folder Browser",
        .folderPreviewTabHelp: "%@, Preview Tab",
        .folderAuthorizationFailed: "Choose a readable folder in its original location.",
        .folderSaveUnavailable: "The original file could not be verified. Your edits are still in this window.",
        .favoriteFolders: "Favorite Folders",
        .favoriteFoldersEmpty: "No Favorite Folders",
        .favoriteFoldersManage: "Remove a Favorite",
        .favoriteFoldersClear: "Clear Favorite Folders",
        .favoriteFolderAddCurrent: "Favorite Current Folder",
        .favoriteFolderRemoveCurrent: "Remove Current Folder from Favorites",
        .favoriteFolderRemove: "Remove from Favorites",
        .favoriteFolderKeep: "Keep",
        .favoriteFolderUnavailable: "Favorite Folder Unavailable",
        .favoriteFolderMoved: "The folder was moved, deleted, or is on a volume that is currently unavailable.",
        .favoriteFolderPermissionDenied: "You don’t have permission to read the folder.",
        .favoriteFolderLink: "The saved path now points to a symbolic link or alias.",
        .favoriteFolderCannotAdd: "Couldn’t Favorite This Folder",
        .favoriteFolderAdded: "Added %@ to Favorite Folders.",
        .favoriteFolderRemoved: "Removed %@ from Favorite Folders.",
        .favoriteFoldersCleared: "Cleared Favorite Folders.",
        .openRecent: "Open Recent",
        .clearMenu: "Clear Menu",
        .recentDocumentMissingDetail: "The file no longer exists at its recorded location.",
        .save: "Save",
        .createCopy: "Create Copy…",
        .createCopyAction: "Create Copy",
        .copyPromptDetail: "Create a new Markdown file in:\n%@\n\nThe copy uses your current editor text, including unsaved edits. Existing images and attachments are shared; they will not be copied or deleted. The original document stays open and keeps any unresolved conflict.",
        .copyNameSuffix: " copy",
        .copyFilename: "Copy filename",
        .copyCreated: "Created Markdown copy: %@",
        .copySaveUnavailable: "The copy could not be verified at its current location. Your edits remain in this window. Locate the actual copy before saving again.",
        .copyOpenFailed: "The copy was created, but it can no longer be opened safely at that location. It may have moved, changed, been removed, or become a link to another file. No new window was opened. Locate the copy in Finder or create a new copy.",
        .copyCreatedDetail: "The copy contains the text captured when you confirmed its name. Existing attachments are shared. Open it separately to continue editing the copy.",
        .openCopy: "Open Copy",
        .dismissCopyNotice: "Dismiss",
        .copyFailed: "Could not create a copy.",
        .copySaveFirst: "Save this untitled document first, then choose Create Copy. The original has not been saved by this command.",
        .copyFinishComposition: "Finish your current input-method composition, then try again. Your provisional text has been kept.",
        .copySourceChanged: "The source document or its location changed. Try Create Copy again from the document you want to copy.",
        .copyInvalidName: "Enter a new filename ending in .md or .markdown, without folder separators or leading or trailing spaces.",
        .copySourceUnavailable: "The source must be an existing local regular file. Reopen or save the document before creating a copy.",
        .copyNameExists: "That filename already exists or refers to the original. Choose a different name; no existing file was replaced.",
        .copyEncodingUnavailable: "The current text cannot be represented in %@. No copy was created and the original encoding is unchanged.",
        .historyBrowse: "Browse Local History…",
        .historyTitle: "Local History",
        .historyDisabled: "Local History is off. Turn it on in Settings to browse or record revisions.",
        .historySaveFirst: "Save the document first to start recording its history.",
        .historySourceChanged: "The file or its location changed. Reopen Local History for this document.",
        .historyLoadFailed: "Could not load local history.",
        .historyRevisionUnavailable: "This revision is missing or damaged. Choose another revision.",
        .historySomeUnavailable: "Some revisions are missing or damaged.",
        .historyCopyFailed: "Could not restore the revision as a copy.",
        .historyCopyOpenFailed: "The copy “%@” was created beside the document but could not be opened safely. Locate it in Finder.",
        .historyEmpty: "There are no saved revisions for this document yet.",
        .historyRevisionOpened: "Opened from disk",
        .historyRevisionSaved: "Saved",
        .historyRevisionExternal: "Reloaded from disk",
        .historyExcerpt: "Revision excerpt",
        .historyEmptyExcerpt: "This revision is empty.",
        .historySelectRevision: "Select a revision to see an excerpt.",
        .historyLoading: "Loading history…",
        .historyRestoring: "Restoring copy…",
        .historyAttachments: "The copy is saved beside the current document. It shares the files that relative links and attachments point to today. History keeps only the Markdown text.",
        .historyRestoreAsCopy: "Restore as Copy…",
        .historyRestoreAndOpen: "Restore and Open",
        .historyCopyNameSuffix: " restored",
        .historyEnabledSetting: "Keep Local History",
        .historySettingDetail: "Markdown2 stores saved text revisions on this Mac and does not sync them. History keeps up to 20 revisions per document for up to 30 days, subject to a storage limit. Turning it off keeps existing revisions until they expire or you delete them.",
        .historyClear: "Delete Local History…",
        .historyClearConfirm: "Delete saved revisions for all documents on this Mac? This cannot be undone.",
        .historyClearAction: "Delete History",
        .historyClearFailed: "Could not delete local history.",
        .exportTo: "Export To",
        .exportPDF: "Export as PDF…",
        .exportHTML: "Export as HTML…",
        .exportDOCX: "Export as DOCX…",
        .exportEPUB: "Export as EPUB…",
        .close: "Close",
        .folderQuickOpenField: "Quick Open",
        .folderFilterPlaceholder: "Search filenames or paths",
        .folderFileList: "Folder Files",
        .folderLandingPrompt: "Choose a Markdown file from the sidebar",
        .folderRefresh: "Refresh",
        .folderCancelScan: "Stop Scan",
        .folderOpenSelection: "Open",
        .folderScanning: "Scanning folder…",
        .folderOpening: "Opening file…",
        .folderNoFiles: "No Markdown files found.",
        .folderOneFile: "1 Markdown file",
        .folderFileCount: "%@ Markdown files",
        .folderOneMatch: "1 matching file",
        .folderMatchCount: "%@ matching files",
        .folderScanLimited: "Partial list. The scan limit was reached.",
        .folderScanUnreadable: "Some items could not be read.",
        .folderScanCancelled: "Scan stopped. Refresh to try again.",
        .folderRefreshCancelled: "Scan stopped. Showing the previous list.",
        .folderRootUnavailable: "The folder is unavailable. Choose it again to continue.",
        .folderFileUnavailable: "This file is unavailable or changed on disk. Refresh the folder and try again.",
        .folderFileTooLarge: "This file is too large to open from the folder browser. Use File › Open to open it directly.",
        .outline: "Outline",
        .noHeadings: "No headings",
        .hideOutline: "Hide outline",
        .showOutline: "Show outline",
        .showMetadata: "Show metadata",
        .hideMetadata: "Hide metadata",
        .navigateToHeading: "Navigate to heading",
        .mode: "Mode",
        .write: "Edit",
        .markdownSource: "Markdown Source",
        .read: "Preview",
        .sideBySide: "Side by Side",
        .writeOrRead: "Edit or preview",
        .modePickerHelp: "Edit (%@), Side by Side (%@), Preview (%@). Change shortcuts in Settings.",
        .formulaEditButton: "Edit Formula…",
        .formulaEditorTitle: "Edit Formula",
        .formulaEditorInstructions: "Enter one nonempty line of TeX without the surrounding $$ delimiters. Press Command-Return to apply.",
        .formulaEditorInput: "Formula (TeX)",
        .formulaApply: "Apply",
        .formulaRevealButton: "Open Formula in Source…",
        .formulaSourceTitle: "Edit This Formula in Source",
        .formulaSourceDetail: "Preview can edit a top-level $$ formula on a single line. Open the source to edit this formula or its containing block.",
        .formulaOpenSource: "Open Source",
        .formulaEditUnavailable: "Could Not Edit Formula",
        .formulaEditUnavailableDetail: "The source has changed or the editor is busy. Finish any active text input and choose the formula again in Preview.",
        .formulaCheckingDraft: "Checking the formula against its Markdown context…",
        .formulaReplacementRequiresSource: "This draft changes how Markdown reads the formula line. Revise the TeX or choose Open Source to edit the Markdown.",
        .typewriterScrolling: "Typewriter Scrolling",
        .words: "words",
        .chars: "chars",
        .lines: "lines",
        .minRead: "min read",
        .ok: "OK",
        .settingsTitle: "Markdown2 Settings",
        .language: "Language",
        .followSystem: "Follow System",
        .english: "English",
        .chineseSimplified: "Simplified Chinese",
        .defaultOpenMode: "Mode When Opening a File",
        .newDocumentMode: "Mode for New Documents",
        .preferTabsForDocuments: "Prefer Tabs for Documents",
        .modeShortcuts: "Mode Shortcuts",
        .resetModeShortcuts: "Reset Shortcuts",
        .clickToRecordShortcut: "Click to record a shortcut",
        .recordingShortcut: "Press shortcut...",
        .shortcutMalformed: "Use a real key with at least one modifier.",
        .shortcutDuplicate: "Shortcut is already assigned to %@.",
        .shortcutAppCommandConflict: "Shortcut is already used by %@.",
        .shortcutSystemConflict: "Shortcut conflicts with macOS %@.",
        .showOutlineByDefault: "Show Outline by Default",
        .general: "General",
        .preferences: "Settings",
        .unsavedChangesTitle: "Save changes before closing?",
        .unsavedChangesMessage: "This document has unsaved changes.",
        .externalChangeConflictTitle: "Keep your edits or reload from disk?",
        .externalChangeConflictMessage: "This document has unsaved changes, and its file was modified outside Markdown2. Keeping your version overwrites the file on the next save.",
        .keepMyVersion: "Keep My Version",
        .reloadFromDisk: "Reload from Disk",
        .linkedSaveInterruptedTitle: "Finish the interrupted save?",
        .linkedSaveInterruptedMessage: "The file contains only the beginning of your recovered draft. Finishing the save updates this file and all its hard-linked names. You can keep the draft and decide later.",
        .finishLinkedSave: "Finish Save",
        .linkedSaveLater: "Later",
        .cancel: "Cancel",
        .dontSave: "Don't Save",
        .alertCouldNotOpen: "Could not open %@.",
        .alertHeadingNotFound: "The linked heading could not be found.",
        .alertHeadingNotFoundDetail: "The document is open, but it has no heading with the identifier “%@”.",
        .alertUndecodableFile: "Could not read %@ as text.",
        .alertUndecodableFileDetail: "The file is not in a supported text encoding (UTF-8, UTF-16/32 with a byte-order mark, or GB18030).",
        .alertCouldNotSave: "Could not save %@.",
        .alertUnverifiedSaveDestination: "Markdown2 could not verify the file at this location. Check its permissions or choose a different location.",
        .alertRecoveryRequiredForLinkedSave: "This file has other hard links. Markdown2 needs a recovery copy before updating them. Restore access to document recovery or use Create Copy to save your edits separately.",
        .alertRecoveryFailed: "Could not write document recovery data. Keep this window open and save your work.",
        .alertRecoveryUnreadable: "Some recovery records could not be read. They have been kept in %@.",
        .encodingConversionTitle: "Save as UTF-8?",
        .encodingConversionMessage: "This document contains characters that %@ cannot represent. Convert to UTF-8 to save them? Cancel keeps the original file unchanged and your edits in the recovery copy.",
        .convertToUTF8: "Convert to UTF-8",
        .mixedLineEndings: "Mixed line endings",

        .alertCouldNotExport: "Could not export %@.",
        .alertHTMLExportIncomplete: "%@ was exported as offline HTML with some images omitted.",
        .alertHTMLExported: "%@ was exported as offline HTML.",
        .alertHTMLExportDiagramResources: "Images generated inside diagrams are not embedded in offline HTML. Unsupported resource styles may be omitted; ordinary vector geometry is retained.",
        .alertHTMLExportRemoteImages: "Remote images were replaced with inactive placeholders:",
        .alertHTMLExportLocalImages: "These local images could not be embedded and were replaced with inactive placeholders:",
        .alertHTMLExportMoreImages: "…and %@ more",
        .alertCouldNotPrint: "Could not print the document.",
        .alertPandocRequired: "Pandoc is required to export %@.",
        .alertPandocRequiredDetail: "Install Pandoc from pandoc.org/installing.html or run brew install pandoc in Terminal, then try exporting again.",
        .conversionDestinationTitle: "Export %@",
        .conversionDestinationNotice: "Pandoc converts Markdown with its own layout and syntax support. Preview diagrams, styles and some Markdown extensions may look different or be omitted. Remote images cannot be downloaded during conversion.",
        .exportConversionProgress: "Exporting %@…",
        .alertExportSourceDestination: "Choose a destination separate from the source document.",
        .alertConversionSourceChanged: "The document changed during export. Try exporting again to use the latest version.",
        .conversionPreparationFailed: "Could not prepare the document or write the export file. Check that the destination folder is writable.",
        .conversionFailed: "Pandoc could not convert the document.",
        .conversionFailedWithDetail: "Pandoc could not convert the document.\n\n%@",
        .conversionDestinationChanged: "The destination changed during conversion. Choose it again to export.",
        .conversionConfinementUnavailable: "This system could not start Pandoc with network access blocked. Export stopped.",
        .conversionCanceled: "Conversion canceled.",
        .conversionTimedOut: "The conversion took too long and was stopped.",
        .alertHTMLExportInvalidImage: "not a valid supported image",
        .alertHTMLExportImageLimit: "exceeds the export image size or decoding limit",
        .alertExternalAttachmentDirectory: "Save images outside this document’s folder?",
        .alertExternalAttachmentDirectoryDetail: "The attachment folder links to:\n%@\n\nUse this folder for pasted images in this document for this session, or cancel and choose a document-local attachment folder in Settings.",
        .useAttachmentFolder: "Use This Folder",
        .alertAttachmentSaveFailed: "Could not save the image attachment.",
        .alertExternalReloadFailedDetail: "The file could not be re-read after it changed on disk.",
        .formatMenu: "Format",
        .paragraphMenu: "Paragraph",
        .formatBold: "Bold",
        .formatItalic: "Italic",
        .formatLink: "Link",
        .formatCodeBlock: "Code Block",
        .formatTable: "Table",
        .tableOperations: "Table Operations",
        .tableInsertRowAbove: "Insert Row Above",
        .tableInsertRowBelow: "Insert Row Below",
        .tableDeleteRow: "Delete Row",
        .tableInsertColumnBefore: "Insert Column Left",
        .tableInsertColumnAfter: "Insert Column Right",
        .tableDeleteColumn: "Delete Column",
        .tableUnsupported: "This table cannot be edited structurally. Use a top-level rectangular pipe table with closed single-backtick code spans.",
        .tableSelectCell: "Place the caret or a single selection inside one table cell, outside the separator row.",
        .tableKeepHeader: "The header and separator rows must remain. Insert below the header to add a body row.",
        .tableKeepColumn: "A table must keep at least one column.",
        .tableLimitReached: "Table editing limit reached: source 500,000 UTF-16 units / 20,000 lines; table 100,000 UTF-16 units, 1,000 rows, 128 columns or 20,000 cells. Edit a smaller table or document.",
        .formatBody: "Body",
        .formatHeading1: "Heading 1",
        .formatHeading2: "Heading 2",
        .formatHeading3: "Heading 3",
        .formatHeading4: "Heading 4",
        .formatHeading5: "Heading 5",
        .formatHeading6: "Heading 6",
        .find: "Find…",
        .findNext: "Find Next",
        .findPrevious: "Find Previous",
        .findReplace: "Find and Replace…",
        .findPlaceholder: "Find",
        .replaceWith: "Replace With",
        .replace: "Replace",
        .replaceAll: "Replace All",
        .pasteAsPlainText: "Paste as Plain Text",
        .pasteAsMarkdown: "Paste as Markdown",
        .pasteAsTable: "Paste as Table",
        .pasteLiteralFallbackNotice: "Formatting was not preserved. The captured plain text was pasted as literal text.",
        .pasteUnavailableNotice: "This clipboard content cannot be converted. Nothing was pasted.",
        .pasteLimitNotice: "Clipboard content exceeds the conversion limit. Nothing was pasted.",
        .pasteUnsafeContextNotice: "Cannot safely paste literal text at this position. Use Paste as Plain Text to insert source text explicitly.",
        .pasteCancelledNotice: "The editing target changed. Paste was canceled.",
        .formattingTargetNotice: "Source selection shown. Select the text to format, then run the command again.",
        .findMatchCase: "Match case",
        .findWholeWord: "Whole word",
        .findRegex: "Regular expression",
        .findRegexHelp: "Use a regular expression to search the Markdown source.",
        .findRegexWholeWordHelp: "Use \\b in the pattern to match a word boundary.",
        .findRegexReplacementHelp: "Use $0 for the whole match, $1 for a numbered group, and ${name} for a named group.",
        .findRegexSearching: "Searching source…",
        .findRegexPreparingReplacement: "Preparing replacement…",
        .findRegexInvalidPattern: "Invalid regular expression. Check the pattern.",
        .findRegexSearchLimit: "Regular-expression search limit exceeded. Simplify the pattern or narrow the selection.",
        .findRegexInvalidReplacement: "Invalid replacement. Check the capture group names and numbers.",
        .findRegexReplacementLimit: "Replacement limit exceeded. Shorten the replacement or narrow the selection.",
        .findRegexSearchFailed: "Regular-expression search could not finish. Edit the pattern to retry.",
        .findRegexMatchCount: "%lld found",
        .findOnlySelection: "Only selection",
        .findSourceSelection: "Source selection",
        .findWholeDocument: "Whole document",
        .findSelectionInvalid: "Selection expired. Select source text again or turn off Only selection.",
        .findSelectionFrozen: "Search is limited to the frozen source selection.",
        .findUseSelection: "Use selection",
        .findSourceOnlyHelp: "Regular expressions, selection scope, and replacement require the source editor.",
        .findScopeCount: "%@ · %d matches",
        .findReplacementCancelled: "Search changed. Replacement canceled; run it again.",
        .findReplacedCount: "%@ · Replaced %d",
        .findPreviewUnavailable: "Search limit exceeded",
        .closeFind: "Close find bar",
        .matchStatus: "%d of %d",
        .noResults: "No results",
        .print: "Print…",
        .openBlankOnLaunch: "Open a blank document on launch",
        .restoreWindowsOnLaunch: "Restore windows when reopening the app",
        .recoveryInterruptedTitle: "Window restoration was interrupted",
        .recoveryInterruptedMessage: "Markdown2 stopped while restoring windows last time. You can skip restoration now; recovery records will be kept.",
        .skipRecovery: "Skip Restoration",
        .restoreRecovery: "Restore Windows",
        .unsavedRecoveryTitle: "Unsaved drafts are available",
        .unsavedRecoveryMessage: "Markdown2 found unsaved drafts from an earlier session. Restore them now?",
        .recoverDrafts: "Recover Drafts",
        .languageChangedTitle: "Restart to apply the new language?",
        .languageChangedMessage: "The menu bar updates to the new language after Markdown2 restarts.",
        .restartNow: "Restart Now",
        .restartLater: "Later",
        .collectLocalImages: "Collect Local Images…",
        .imageFileHandling: "Dropped / Pasted Image Files",
        .imageFileCopy: "Copy to Attachment Folder (Default)",
        .imageFileLink: "Link Original Location",
        .attachmentReport: "Image Attachments",
        .attachmentWrittenCount: "%@ new image files saved. Undo does not delete attachments.",
        .attachmentReferenceCount: "%@ image references ready.",
        .attachmentStale: "The document, selection or input state changed. Source text was not changed; completed copies remain in the attachment folder.",
        .attachmentCollectionScope: "Scope: simple top-level inline Markdown images only. Reference-style images, containers (lists/quotes), code, HTML, math, diagram internals and SVG-internal resources are not collected. Remote resources are never downloaded. Move the document together with its local attachment folder.",
        .attachmentUnsupportedSyntax: "Unsupported image syntax; left unchanged",
        .attachmentExcludedBlocks: "Blocks excluded from the supported scope",
        .attachmentNonlocal: "Remote, embedded or unsupported URL; left unchanged",
        .attachmentInvalidImage: "Not a supported, complete image",
        .attachmentResourceLimit: "Image size or decoding limit exceeded",
        .attachmentReadWriteFailed: "Missing, unreadable image or attachment write failed",
        .attachmentDestinationChanged: "Attachment folder changed; choose the external location again",
        .attachmentScanLimit: "Document exceeds the safe collection scan limit; nothing changed",
        .attachmentExternalNotPortable: "External attachment folder: moving this document directory alone will not carry these images",
        .attachmentFolder: "Image Attachment Folder",
        .attachmentFolderHelp: "Copied image files and screenshots are saved in this document-relative folder. Move it together with the document. Defaults to assets.",
        .imageNotFound: "Image not found",
        .remoteImageUnavailable: "Remote image could not be loaded",
        .remoteImages: "Remote Images",
        .remoteImagesBlocked: "Remote image loading blocked",
        .remoteImagesAllowed: "Remote images allowed for this session",
        .remoteImagesAllow: "Allow for This Document…",
        .remoteImagesAllowConfirm: "Allow Remote Images",
        .remoteImagesRevoke: "Block Remote Images",
        .remoteImagesExplanation: "Allow HTTP(S) images in this document’s preview, PDF export and Print, including images in CSS and diagrams. Other remote resource types stay blocked. This permission applies only to this window and session; opening, reloading or recovering a document resets it.",
        .remoteImagesPrivacy: "Loading remote images reveals your network address and request information to their servers. You can block images again at any time; requests already sent cannot be recalled.",
        .remoteImagesAllowedExplanation: "HTTP(S) images may load in this document’s preview, PDF export and Print. Offline HTML always blocks them.",
        .remoteImagesPreparing: "Preparing a new preview…",
        .remoteImagesDetails: "Details…",
        .remoteImagesDetailsTitle: "Remote Resource Details",
        .remoteImagesOrigins: "Declared image origins and counts",
        .remoteImagesOriginCount: "%@ — %lld",
        .remoteImagesDetailsScope: "Counts cover supported HTTP(S) image references declared in Markdown, HTML, CSS, SVG, and diagram source. Only statically recognized references are counted.",
        .remoteImagesDetailsOtherBlocked: "Remote scripts, stylesheets, fonts, frames and media stay blocked.",
        .remoteImagesDetailsUnknown: "Blocked request count and redirect destinations are unknown.",
        .remoteImagesDetailsInspecting: "Inspecting the preview…",
        .remoteImagesNoReferences: "No remote image references found in this scope.",
        .remoteImagesDetailsPartial: "This list is incomplete. Some references could not be classified or exceeded inspection limits.",
        .remoteImagesPermissions: "Permissions…",
        .remoteImagesFolderPermissions: "Folder Permissions",
        .remoteImagesFolderAllow: "Allow for This Folder…",
        .remoteImagesFolderRevoke: "Remove Folder Permission",
        .remoteImagesFolderConfirmTitle: "Allow Remote Images for This Folder",
        .remoteImagesFolderExplanation: "Allow HTTP(S) images in the preview, PDF export and print of Markdown files opened from this folder or its subfolders. Other remote resources stay blocked.",
        .remoteImagesFolderSession: "This permission lasts while the folder is open.",
        .remoteImagesFolderCanFavorite: "This permission lasts while the folder is open. Adding it to Favorites saves the permission for later.",
        .remoteImagesFolderFavorite: "This permission is saved for this favorite folder. Removing the folder from Favorites revokes it.",
        .remoteImagesAllowedByFolder: "Remote images allowed by folder",
        .remoteImagesAllowedByDocument: "Remote images allowed for this document",
        .remoteImagesBlockedByDocument: "Remote images blocked in this document",
        .remoteImagesBlockDocument: "Block in This Document",
        .remoteImagesUseFolderPermission: "Use Folder Permission",
        .remoteImageBlocked: "Remote image blocked — use the document’s Remote Images control to allow it",
        .offlineHTMLRemoteImageBlocked: "Remote image omitted from offline HTML",
        .offlineHTMLLocalImageUnavailable: "Image could not be embedded in offline HTML",
        .alertExternalFormatExported: "%@ was exported.",
        .alertExternalFormatNetworkBoundary: "Network access was blocked during conversion. Word and EPUB readers are outside this app’s policy and may load remote resources when opening the file. Use HTML or PDF for controlled offline sharing.",
        .imageLoadFailed: "Image could not be loaded",
        .exportSettings: "Export",
        .pageSizeLabel: "Page Size",
        .orientationLabel: "Orientation",
        .orientationPortrait: "Portrait",
        .orientationLandscape: "Landscape",
        .marginsLabel: "Margins",
        .marginNone: "None",
        .marginNarrow: "Narrow",
        .marginNormal: "Normal",
        .marginWide: "Wide",
        .marginCustom: "Custom",
        .marginTop: "Top",
        .marginLeft: "Left",
        .marginBottom: "Bottom",
        .marginRight: "Right",
        .pageNumbers: "Page Numbers",
        .pageNumberPosition: "Page Number Position",
        .pageHeader: "Header",
        .pageFooter: "Footer",
        .zoneLeft: "Left",
        .zoneCenter: "Center",
        .zoneRight: "Right",
        .runningTextTokensHelp: "Header and footer text can use {title}, {date}, {page}, and {pageCount}.",
        .academic: "Academic",
        .markdownSyntax: "Markdown Syntax",
        .enablesHighlight: "Highlight (==text==)",
        .enablesSuperscript: "Superscript (x^2^)",
        .enablesSubscript: "Subscript (H~2~O)",
        .subscriptHelp: "Subscript text cannot contain Chinese punctuation or spaces; ranges such as 3~5 days remain plain text.",
        .citationStyleLabel: "Citation Style",
        .citationAuthorYear: "Author-Year",
        .citationNumeric: "Numeric",
        .numberAllEquations: "Number All Equations",
        .academicHelp: "Citations load from a bibliography: front-matter field or a references.bib next to the document.",
        .lineNumbers: "Line Numbers",
        .lineNumbersInEditor: "Show in the editor",
        .lineNumbersInPreview: "Show in the preview",
        .lineNumbersHelp: "Show source line numbers in the editor, the preview, or both."
    ]

    private static let zhHans: [L10nKey: String] = [
        .typography: "缩放与排版", .editorFont: "编辑字体", .readingFont: "阅读字体",
        .fontSize: "基础字号", .readingWidth: "阅读宽度", .zoom: "缩放",
        .readingWidthHelp: "调整预览正文的宽度。",
        .zoomIn: "放大", .zoomOut: "缩小", .resetZoom: "实际大小",
        .fontSystem: "系统字体", .fontSerif: "衬线字体", .fontMonospaced: "等宽字体",
        .readingNarrow: "窄", .readingComfortable: "适中", .readingWide: "宽", .readingFull: "全宽",
        .selectionStats: "选区",
        .new: "新建",
        .open: "打开...",
        .openFolder: "打开文件夹…",
        .folderQuickOpen: "快速打开…",
        .folderSidebarFiles: "文件",
        .showSidebar: "显示侧栏",
        .hideSidebar: "隐藏侧栏",
        .focusFolderBrowser: "聚焦文件浏览器",
        .revealInFolderBrowser: "在文件浏览器中显示",
        .folderPreviewTabHelp: "%@，预览标签页",
        .folderAuthorizationFailed: "请选择位于原始位置且可读取的文件夹。",
        .folderSaveUnavailable: "无法验证原文件。编辑内容仍保留在此窗口中。",
        .favoriteFolders: "收藏的文件夹",
        .favoriteFoldersEmpty: "暂无收藏的文件夹",
        .favoriteFoldersManage: "移除收藏项",
        .favoriteFoldersClear: "清空收藏夹",
        .favoriteFolderAddCurrent: "收藏当前文件夹",
        .favoriteFolderRemoveCurrent: "从收藏夹移除当前文件夹",
        .favoriteFolderRemove: "从收藏夹移除",
        .favoriteFolderKeep: "保留",
        .favoriteFolderUnavailable: "收藏的文件夹不可用",
        .favoriteFolderMoved: "文件夹已移动、删除，或所在的存储卷暂时不可用。",
        .favoriteFolderPermissionDenied: "你没有读取此文件夹的权限。",
        .favoriteFolderLink: "收藏的路径现在指向符号链接或替身。",
        .favoriteFolderCannotAdd: "无法收藏此文件夹",
        .favoriteFolderAdded: "已收藏 %@。",
        .favoriteFolderRemoved: "已从收藏夹移除 %@。",
        .favoriteFoldersCleared: "已清空收藏夹。",
        .openRecent: "打开最近使用的",
        .clearMenu: "清除菜单",
        .recentDocumentMissingDetail: "文件已不在原来的位置（可能已被移动或删除）。",
        .save: "保存",
        .createCopy: "创建副本…",
        .createCopyAction: "创建副本",
        .copyPromptDetail: "在以下文件夹中新建 Markdown 文件：\n%@\n\n副本包含当前编辑内容（包括未保存的修改）。现有图片和附件由两份文档共享，不会复制或删除。原文档保持打开，已有冲突仍需另行处理。",
        .copyNameSuffix: " 副本",
        .copyFilename: "副本文件名",
        .copyCreated: "已创建 Markdown 副本：%@",
        .copySaveUnavailable: "无法在当前位置确认副本身份。编辑内容仍保留在当前窗口中；请先找到实际副本，再保存。",
        .copyOpenFailed: "副本已创建，但目前无法在该位置安全打开：它可能已移动、更改、删除，或与其他文件建立了链接。未打开新窗口。请在 Finder 中查找副本，或重新创建副本。",
        .copyCreatedDetail: "副本包含确认名称时的编辑内容，继续共享现有附件。可单独打开副本继续编辑。",
        .openCopy: "打开副本",
        .dismissCopyNotice: "关闭提示",
        .copyFailed: "无法创建副本。",
        .copySaveFirst: "请先保存未命名文档，再选择“创建副本”。此命令未保存原稿。",
        .copyFinishComposition: "请先完成当前输入法组词，再重试。正在输入的文字已保留。",
        .copySourceChanged: "原文档或位置已改变。请在要复制的文档中重新选择“创建副本”。",
        .copyInvalidName: "请输入以 .md 或 .markdown 结尾的新文件名，不含文件夹分隔符及首尾空格。",
        .copySourceUnavailable: "原稿必须是已存在的本地普通文件。请先重新打开或保存文档，再创建副本。",
        .copyNameExists: "该名称已存在或指向原稿。请换一个名称；没有覆盖任何已有文件。",
        .copyEncodingUnavailable: "当前内容含有 %@ 无法表示的字符。未创建副本，原稿编码保持不变。",
        .historyBrowse: "浏览本地历史版本…",
        .historyTitle: "本地历史版本",
        .historyDisabled: "本地历史版本已关闭。请在设置中启用后浏览或记录历史版本。",
        .historySaveFirst: "请先保存文档，开始记录历史版本。",
        .historySourceChanged: "文档或其位置已更改。请重新打开此文档的本地历史版本。",
        .historyLoadFailed: "无法读取本地历史版本。",
        .historyRevisionUnavailable: "此版本已丢失或损坏。请选择其他版本。",
        .historySomeUnavailable: "部分历史版本已丢失或损坏。",
        .historyCopyFailed: "无法将所选版本恢复为副本。",
        .historyCopyOpenFailed: "副本“%@”已保存在原文档旁，但无法安全打开。请在访达中查找。",
        .historyEmpty: "此文档暂无历史版本。",
        .historyRevisionOpened: "从磁盘打开",
        .historyRevisionSaved: "已保存",
        .historyRevisionExternal: "从磁盘重新载入",
        .historyExcerpt: "版本内容节选",
        .historyEmptyExcerpt: "此版本没有内容。",
        .historySelectRevision: "请选择要查看的版本。",
        .historyLoading: "正在读取历史版本…",
        .historyRestoring: "正在恢复副本…",
        .historyAttachments: "副本保存在当前文档所在的文件夹，与原文档共享相对链接和附件指向的现有文件。历史版本只保留 Markdown 正文。",
        .historyRestoreAsCopy: "恢复为副本…",
        .historyRestoreAndOpen: "恢复并打开",
        .historyCopyNameSuffix: " 恢复副本",
        .historyEnabledSetting: "保留本地历史版本",
        .historySettingDetail: "Markdown2 将已保存的正文版本保留在这台 Mac 上，不会同步。每份文档最多保留 20 个版本，最长 30 天，同时受存储上限约束。关闭后，已有版本将保留至到期或手动删除。",
        .historyClear: "删除本地历史版本…",
        .historyClearConfirm: "删除这台 Mac 上所有文档的历史版本？此操作无法撤销。",
        .historyClearAction: "删除历史版本",
        .historyClearFailed: "无法删除本地历史版本。",
        .exportTo: "导出到",
        .exportPDF: "导出为 PDF…",
        .exportHTML: "导出为 HTML…",
        .exportDOCX: "导出为 DOCX…",
        .exportEPUB: "导出为 EPUB…",
        .close: "关闭",
        .folderQuickOpenField: "快速打开",
        .folderFilterPlaceholder: "搜索文件名或路径",
        .folderFileList: "文件夹中的文件",
        .folderLandingPrompt: "从侧栏选择一个 Markdown 文件",
        .folderRefresh: "刷新",
        .folderCancelScan: "停止扫描",
        .folderOpenSelection: "打开",
        .folderScanning: "正在扫描文件夹…",
        .folderOpening: "正在打开文件…",
        .folderNoFiles: "未找到 Markdown 文件。",
        .folderOneFile: "1 个 Markdown 文件",
        .folderFileCount: "%@ 个 Markdown 文件",
        .folderOneMatch: "1 个匹配的文件",
        .folderMatchCount: "%@ 个匹配的文件",
        .folderScanLimited: "已达到扫描上限，仅显示部分结果。",
        .folderScanUnreadable: "部分项目无法读取。",
        .folderScanCancelled: "扫描已停止。可刷新后重试。",
        .folderRefreshCancelled: "扫描已停止，当前显示上一次的列表。",
        .folderRootUnavailable: "文件夹不可用。请重新选择文件夹。",
        .folderFileUnavailable: "此文件不可用或已在磁盘上发生变化。请刷新文件夹后重试。",
        .folderFileTooLarge: "此文件过大，无法从文件夹浏览器打开。请使用「文件」菜单中的「打开」。",
        .outline: "大纲",
        .noHeadings: "没有标题",
        .hideOutline: "隐藏大纲",
        .showOutline: "显示大纲",
        .showMetadata: "显示元数据",
        .hideMetadata: "隐藏元数据",
        .navigateToHeading: "跳转到标题",
        .mode: "模式",
        .write: "编辑",
        .markdownSource: "Markdown 源码",
        .read: "预览",
        .sideBySide: "双栏",
        .writeOrRead: "编辑或预览",
        .modePickerHelp: "编辑（%@）、双栏（%@）、预览（%@）。可在设置中修改快捷键。",
        .formulaEditButton: "编辑公式…",
        .formulaEditorTitle: "编辑公式",
        .formulaEditorInstructions: "输入一行非空的 TeX，无需输入两端的 $$ 定界符。按 Command-Return 应用。",
        .formulaEditorInput: "公式（TeX）",
        .formulaApply: "应用",
        .formulaRevealButton: "在源码中打开公式…",
        .formulaSourceTitle: "在源码中编辑此公式",
        .formulaSourceDetail: "预览中可直接编辑独占一行的顶层 $$ 公式。请打开源码编辑此公式或包含它的内容块。",
        .formulaOpenSource: "打开源码",
        .formulaEditUnavailable: "无法编辑公式",
        .formulaEditUnavailableDetail: "源码已更改或编辑器正在处理输入。请先完成当前输入，再在预览中选择公式。",
        .formulaCheckingDraft: "正在检查公式所在的 Markdown 上下文…",
        .formulaReplacementRequiresSource: "当前内容会改变 Markdown 对公式所在行的解析。请修改 TeX，或选择「打开源码」编辑 Markdown。",
        .typewriterScrolling: "打字机滚动",
        .words: "字",
        .chars: "字符",
        .lines: "行",
        .minRead: "分钟阅读",
        .ok: "好",
        .settingsTitle: "Markdown2 设置",
        .language: "语言",
        .followSystem: "跟随系统",
        .english: "英语",
        .chineseSimplified: "简体中文",
        .defaultOpenMode: "打开文件时的模式",
        .newDocumentMode: "新建文档时的模式",
        .preferTabsForDocuments: "优先在标签页中打开文稿",
        .modeShortcuts: "模式快捷键",
        .resetModeShortcuts: "重置快捷键",
        .clickToRecordShortcut: "点击录制快捷键",
        .recordingShortcut: "按下快捷键...",
        .shortcutMalformed: "请使用真实按键，并至少包含一个修饰键。",
        .shortcutDuplicate: "该快捷键已分配给 %@。",
        .shortcutAppCommandConflict: "该快捷键已被 %@ 使用。",
        .shortcutSystemConflict: "该快捷键与 macOS %@ 冲突。",
        .showOutlineByDefault: "默认显示大纲",
        .general: "通用",
        .preferences: "设置",
        .unsavedChangesTitle: "关闭前保存更改？",
        .unsavedChangesMessage: "当前文档还有未保存的更改。",
        .externalChangeConflictTitle: "保留你的修改，还是从磁盘重新载入？",
        .externalChangeConflictMessage: "当前文档有未保存的更改，同时文件已在 Markdown2 之外被修改。选择保留后，下次保存将覆盖磁盘上的文件。",
        .keepMyVersion: "保留我的版本",
        .reloadFromDisk: "从磁盘重新载入",
        .linkedSaveInterruptedTitle: "继续完成中断的保存？",
        .linkedSaveInterruptedMessage: "磁盘上的文件只包含恢复草稿的开头。继续保存会更新该文件及其所有硬链接。你可以保留草稿，稍后再决定。",
        .finishLinkedSave: "继续保存",
        .linkedSaveLater: "稍后",
        .cancel: "取消",
        .dontSave: "不保存",
        .alertCouldNotOpen: "无法打开 %@。",
        .alertHeadingNotFound: "找不到链接指向的章节。",
        .alertHeadingNotFoundDetail: "文档已打开，但没有标识为“%@”的标题。",
        .alertUndecodableFile: "无法将 %@ 作为文本读取。",
        .alertUndecodableFileDetail: "文件不是受支持的文本编码（UTF-8、带字节序标记的 UTF-16/32，或 GB18030）。",
        .alertCouldNotSave: "无法保存 %@。",
        .alertUnverifiedSaveDestination: "Markdown2 无法确认此位置的文件。请检查文件权限或选择其他保存位置。",
        .alertRecoveryRequiredForLinkedSave: "此文件还有其他硬链接。Markdown2 需要先写入恢复副本才能更新文件。请恢复文档恢复目录的访问权限，或使用“创建副本”另存编辑内容。",
        .alertRecoveryFailed: "无法写入文档恢复数据。请保持窗口打开并保存文稿。",
        .alertRecoveryUnreadable: "部分恢复记录无法读取，已保留在 %@。",
        .encodingConversionTitle: "转换为 UTF-8 保存？",
        .encodingConversionMessage: "当前文档包含 %@ 无法表示的字符。是否转换为 UTF-8 保存？取消会保留原文件，编辑内容留在恢复副本中。",
        .convertToUTF8: "转换为 UTF-8",
        .mixedLineEndings: "混合换行符",

        .alertCouldNotExport: "无法导出 %@。",
        .alertHTMLExportIncomplete: "%@ 已导出为离线 HTML，部分图片已省略。",
        .alertHTMLExported: "%@ 已导出为离线 HTML。",
        .alertHTMLExportDiagramResources: "离线 HTML 不会嵌入图表内部生成的图片；不支持的资源样式可能被省略，普通矢量图形会保留。",
        .alertHTMLExportRemoteImages: "以下远程图片已替换为不可加载的占位提示：",
        .alertHTMLExportLocalImages: "以下本地图片无法嵌入，已替换为不可加载的占位提示：",
        .alertHTMLExportMoreImages: "另有 %@ 张未列出",
        .alertCouldNotPrint: "无法打印文档。",
        .alertPandocRequired: "导出 %@ 需要 Pandoc。",
        .alertPandocRequiredDetail: "请从 pandoc.org/installing.html 安装 Pandoc，或在终端运行 brew install pandoc，然后重试导出。",
        .conversionDestinationTitle: "导出 %@",
        .conversionDestinationNotice: "Pandoc 使用自己的排版和语法规则转换 Markdown。预览中的图表、样式和部分 Markdown 扩展语法可能显示不同或被省略。转换期间无法下载远程图片。",
        .exportConversionProgress: "正在导出 %@…",
        .alertExportSourceDestination: "请选择与源文档不同的目标文件。",
        .alertConversionSourceChanged: "导出期间文档发生了变化。请重新导出以使用最新版本。",
        .conversionPreparationFailed: "无法准备文档或写入导出文件。请检查目标文件夹是否可写。",
        .conversionFailed: "Pandoc 无法转换文档。",
        .conversionFailedWithDetail: "Pandoc 无法转换文档。\n\n%@",
        .conversionDestinationChanged: "转换期间目标文件发生了变化。请重新选择目标文件后再导出。",
        .conversionConfinementUnavailable: "当前系统无法在阻止网络访问的条件下启动 Pandoc，导出已停止。",
        .conversionCanceled: "转换已取消。",
        .conversionTimedOut: "转换超时，已停止。",
        .alertHTMLExportInvalidImage: "不是有效的受支持图片",
        .alertHTMLExportImageLimit: "超出导出图片大小或解码限制",
        .alertExternalAttachmentDirectory: "将图片保存到文档文件夹之外？",
        .alertExternalAttachmentDirectoryDetail: "附件文件夹链接到：\n%@\n\n可选择在本次会话中将此文档粘贴的图片保存到该位置，或取消并在设置中选择文档内的附件文件夹。",
        .useAttachmentFolder: "使用此文件夹",
        .alertAttachmentSaveFailed: "无法保存图片附件。",
        .alertExternalReloadFailedDetail: "文件在磁盘上发生变化后无法重新读取。",
        .formatMenu: "格式",
        .paragraphMenu: "段落",
        .formatBold: "粗体",
        .formatItalic: "斜体",
        .formatLink: "链接",
        .formatCodeBlock: "代码块",
        .formatTable: "表格",
        .tableOperations: "表格操作",
        .tableInsertRowAbove: "在上方插入行",
        .tableInsertRowBelow: "在下方插入行",
        .tableDeleteRow: "删除行",
        .tableInsertColumnBefore: "在左侧插入列",
        .tableInsertColumnAfter: "在右侧插入列",
        .tableDeleteColumn: "删除列",
        .tableUnsupported: "此处暂不支持结构编辑。请使用顶层、各行列数一致的竖线表格；代码片段需使用闭合的单反引号。",
        .tableSelectCell: "请将光标或单一选区放在一个内容单元格内，避开分隔行。",
        .tableKeepHeader: "必须保留表头和分隔行。可在表头下方插入正文行。",
        .tableKeepColumn: "表格必须至少保留一列。",
        .tableLimitReached: "已达到表格编辑上限：全文 500,000 个 UTF-16 单元 / 20,000 行；表格 100,000 个 UTF-16 单元、1,000 行、128 列或 20,000 格。请缩小表格或文档后操作。",
        .formatBody: "正文",
        .formatHeading1: "一级标题",
        .formatHeading2: "二级标题",
        .formatHeading3: "三级标题",
        .formatHeading4: "四级标题",
        .formatHeading5: "五级标题",
        .formatHeading6: "六级标题",
        .find: "查找…",
        .findNext: "查找下一个",
        .findPrevious: "查找上一个",
        .findReplace: "查找与替换…",
        .findPlaceholder: "查找",
        .replaceWith: "替换为",
        .replace: "替换",
        .replaceAll: "全部替换",
        .pasteAsPlainText: "粘贴为纯文本",
        .pasteAsMarkdown: "粘贴为 Markdown",
        .pasteAsTable: "粘贴为表格",
        .pasteLiteralFallbackNotice: "未保留格式，已将捕获的纯文本表示作为字面文字粘贴。",
        .pasteUnavailableNotice: "无法转换此剪贴板内容，未粘贴任何内容。",
        .pasteLimitNotice: "剪贴板内容超出转换限制，未粘贴任何内容。",
        .pasteUnsafeContextNotice: "无法在此位置安全地粘贴字面文字。如需插入源码，请显式选择“粘贴为纯文本”。",
        .pasteCancelledNotice: "编辑目标已变化，粘贴已取消。",
        .formattingTargetNotice: "已显示源码选区。请选择要格式化的文字，再次执行命令。",
        .findMatchCase: "区分大小写",
        .findWholeWord: "整词",
        .findRegex: "正则表达式",
        .findRegexHelp: "使用正则表达式查找 Markdown 源码。",
        .findRegexWholeWordHelp: "用 \\b 匹配单词边界。",
        .findRegexReplacementHelp: "用 $0 引用整个匹配，用 $1 引用编号捕获组，用 ${name} 引用命名捕获组。",
        .findRegexSearching: "正在查找源码…",
        .findRegexPreparingReplacement: "正在准备替换…",
        .findRegexInvalidPattern: "正则表达式无效。请检查表达式。",
        .findRegexSearchLimit: "超出正则表达式查找限制。请简化表达式或缩小选区。",
        .findRegexInvalidReplacement: "替换内容无效。请检查捕获组的名称和编号。",
        .findRegexReplacementLimit: "超出替换限制。请缩短替换内容或缩小选区。",
        .findRegexSearchFailed: "正则表达式查找未能完成。请编辑表达式后重试。",
        .findRegexMatchCount: "%lld 处匹配",
        .findOnlySelection: "仅选区",
        .findSourceSelection: "源码选区",
        .findWholeDocument: "全文",
        .findSelectionInvalid: "选区已失效。请重新选择源码，或关闭“仅选区”。",
        .findSelectionFrozen: "查找范围已固定为源码选区。",
        .findUseSelection: "使用选区",
        .findSourceOnlyHelp: "正则表达式、仅选区和替换需在源码编辑器中使用。",
        .findScopeCount: "%@ · %d 处匹配",
        .findReplacementCancelled: "查找状态已变化，替换已取消。请重新执行。",
        .findReplacedCount: "%@ · 已替换 %d 处",
        .findPreviewUnavailable: "超出查找限制",
        .closeFind: "关闭查找栏",
        .matchStatus: "第 %d 个，共 %d 个",
        .noResults: "无结果",
        .print: "打印…",
        .openBlankOnLaunch: "启动时打开空白文档",
        .restoreWindowsOnLaunch: "重新打开 App 时恢复窗口",
        .recoveryInterruptedTitle: "上次恢复窗口时中断",
        .recoveryInterruptedMessage: "Markdown2 上次恢复窗口时意外退出。可以暂时跳过恢复；恢复记录会保留。",
        .skipRecovery: "跳过恢复",
        .restoreRecovery: "恢复窗口",
        .unsavedRecoveryTitle: "发现未保存的草稿",
        .unsavedRecoveryMessage: "Markdown2 发现之前会话中未保存的草稿。现在恢复吗？",
        .recoverDrafts: "恢复草稿",
        .languageChangedTitle: "重启以应用新语言？",
        .languageChangedMessage: "菜单栏将在 Markdown2 重启后切换到新语言。",
        .restartNow: "立即重启",
        .restartLater: "稍后",
        .collectLocalImages: "收集本地图片…",
        .imageFileHandling: "拖入或粘贴的图片文件",
        .imageFileCopy: "复制到附件文件夹（默认）",
        .imageFileLink: "链接原位置",
        .attachmentReport: "图片附件",
        .attachmentWrittenCount: "已保存 %@ 个新图片文件。撤销不会删除附件。",
        .attachmentReferenceCount: "已处理 %@ 处图片引用。",
        .attachmentStale: "文档、选区或输入状态已改变，未修改源文本；已复制的图片保留在附件文件夹。",
        .attachmentCollectionScope: "范围：仅收集简单顶层行内 Markdown 图片。引用式图片、列表/引用等容器、代码、HTML、公式、图表及 SVG 内部资源不在范围内；不会下载网络资源。移动资料时请连同本地附件文件夹一起移动。",
        .attachmentUnsupportedSyntax: "不支持的图片语法，已保留原文",
        .attachmentExcludedBlocks: "因超出支持范围而保留的文本块数",
        .attachmentNonlocal: "网络、内嵌或不支持的 URL，已保留原文",
        .attachmentInvalidImage: "不是受支持的完整图片",
        .attachmentResourceLimit: "图片大小或解码量超过上限",
        .attachmentReadWriteFailed: "图片缺失、无法读取或附件写入失败",
        .attachmentDestinationChanged: "附件文件夹已改变，请重新选择外部位置",
        .attachmentScanLimit: "文档超过安全扫描上限，未作更改",
        .attachmentExternalNotPortable: "附件文件夹位于外部：仅移动文档目录不会携带这些图片",
        .attachmentFolder: "图片附件文件夹",
        .attachmentFolderHelp: "复制的图片文件和截图保存在此相对文档的文件夹中。移动文档时请连同它一起移动。默认为 assets。",
        .imageNotFound: "找不到图片",
        .remoteImageUnavailable: "无法加载远程图片",
        .remoteImages: "远程图片",
        .remoteImagesBlocked: "远程图片加载已阻止",
        .remoteImagesAllowed: "本次会话已允许远程图片",
        .remoteImagesAllow: "为本文档允许…",
        .remoteImagesAllowConfirm: "允许远程图片",
        .remoteImagesRevoke: "阻止远程图片",
        .remoteImagesExplanation: "允许本文档在预览、PDF 导出和打印时加载 HTTP(S) 图片，包括 CSS 和图表中的图片。其他远程资源仍被阻止。许可仅对当前窗口和本次会话有效；打开、重新加载或恢复文档后将重置。",
        .remoteImagesPrivacy: "加载远程图片会向其服务器透露你的网络地址和请求信息。你可随时再次阻止，但已发送的请求无法撤回。",
        .remoteImagesAllowedExplanation: "本文档在预览、PDF 导出和打印时可加载 HTTP(S) 图片。离线 HTML 始终阻止远程图片。",
        .remoteImagesPreparing: "正在准备新预览…",
        .remoteImagesDetails: "详情…",
        .remoteImagesDetailsTitle: "远程资源详情",
        .remoteImagesOrigins: "已声明的图片来源及引用数",
        .remoteImagesOriginCount: "%@ — %lld",
        .remoteImagesDetailsScope: "此处统计 Markdown、HTML、CSS、SVG 和图表源码中受支持的 HTTP(S) 图片引用。仅统计可静态识别的引用。",
        .remoteImagesDetailsOtherBlocked: "远程脚本、样式表、字体、网页框架和媒体始终被阻止。",
        .remoteImagesDetailsUnknown: "实际拦截的请求数和重定向目的地未知。",
        .remoteImagesDetailsInspecting: "正在检查预览…",
        .remoteImagesNoReferences: "此范围内未发现远程图片引用。",
        .remoteImagesDetailsPartial: "列表不完整。部分引用无法识别，或超出了检查范围。",
        .remoteImagesPermissions: "权限…",
        .remoteImagesFolderPermissions: "文件夹权限",
        .remoteImagesFolderAllow: "为此文件夹允许…",
        .remoteImagesFolderRevoke: "撤销文件夹权限",
        .remoteImagesFolderConfirmTitle: "允许此文件夹加载远程图片",
        .remoteImagesFolderExplanation: "允许在预览、导出 PDF 和打印从此文件夹或其子文件夹打开的 Markdown 文件时加载 HTTP(S) 图片。其他远程资源仍被阻止。",
        .remoteImagesFolderSession: "此权限在文件夹打开期间有效。",
        .remoteImagesFolderCanFavorite: "此权限在文件夹打开期间有效。收藏此文件夹后，下次打开时也会保留权限。",
        .remoteImagesFolderFavorite: "此权限将随收藏文件夹保存。移除收藏会撤销权限。",
        .remoteImagesAllowedByFolder: "远程图片由文件夹权限允许",
        .remoteImagesAllowedByDocument: "已为本文档允许远程图片",
        .remoteImagesBlockedByDocument: "已为本文档阻止远程图片",
        .remoteImagesBlockDocument: "在本文档中阻止",
        .remoteImagesUseFolderPermission: "使用文件夹权限",
        .remoteImageBlocked: "远程图片已阻止，可通过本文档的「远程图片」控件允许加载",
        .offlineHTMLRemoteImageBlocked: "离线 HTML 已省略远程图片",
        .offlineHTMLLocalImageUnavailable: "此图片无法嵌入离线 HTML",
        .alertExternalFormatExported: "已导出 %@。",
        .alertExternalFormatNetworkBoundary: "转换期间已禁止网络访问。Word 和 EPUB 阅读器不受本应用的策略约束，打开文件时可能加载远程资源。如需受控的离线分享，请使用 HTML 或 PDF。",
        .imageLoadFailed: "无法加载图片",
        .exportSettings: "导出",
        .pageSizeLabel: "页面大小",
        .orientationLabel: "方向",
        .orientationPortrait: "纵向",
        .orientationLandscape: "横向",
        .marginsLabel: "页边距",
        .marginNone: "无",
        .marginNarrow: "窄",
        .marginNormal: "正常",
        .marginWide: "宽",
        .marginCustom: "自定义",
        .marginTop: "上",
        .marginLeft: "左",
        .marginBottom: "下",
        .marginRight: "右",
        .pageNumbers: "页码",
        .pageNumberPosition: "页码位置",
        .pageHeader: "页眉",
        .pageFooter: "页脚",
        .zoneLeft: "左",
        .zoneCenter: "中",
        .zoneRight: "右",
        .runningTextTokensHelp: "页眉和页脚文本可使用 {title}、{date}、{page} 和 {pageCount}。",
        .academic: "学术",
        .markdownSyntax: "Markdown 语法",
        .enablesHighlight: "高亮（==文字==）",
        .enablesSuperscript: "上标（x^2^）",
        .enablesSubscript: "下标（H~2~O）",
        .subscriptHelp: "下标内容不能包含中文标点或空格；3~5天一类的范围写法保持原样。",
        .citationStyleLabel: "引用样式",
        .citationAuthorYear: "作者-年份",
        .citationNumeric: "数字编号",
        .numberAllEquations: "为所有公式编号",
        .academicHelp: "引用会从 front-matter 的 bibliography: 字段或文档同目录下的 references.bib 加载。",
        .lineNumbers: "行号",
        .lineNumbersInEditor: "在编辑模式显示",
        .lineNumbersInPreview: "在预览模式显示",
        .lineNumbersHelp: "在编辑、预览或两者中显示源码行号。"
    ]
}
