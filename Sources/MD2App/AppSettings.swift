import Foundation
import MD2Core

@MainActor
final class AppSettings: ObservableObject {
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

    /// Document-relative folder where raw clipboard images are stored, e.g.
    /// `assets` or `images/screenshots`. Dropped/pasted image files are linked
    /// in place. The raw user value is kept as-typed; it is normalized
    /// (absolute/`..`/escaping paths rejected back to `assets`) at write time by
    /// `ImageAttachmentManager`.
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

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        let languageValue = defaults.string(forKey: Keys.language) ?? AppLanguage.system.rawValue
        language = AppLanguage(rawValue: languageValue) ?? .system

        let modeValue = defaults.string(forKey: Keys.defaultMode) ?? EditorMode.write.rawValue
        defaultMode = EditorMode(rawValue: modeValue) ?? .write

        let newModeValue = defaults.string(forKey: Keys.newDocumentMode) ?? EditorMode.write.rawValue
        newDocumentMode = EditorMode(rawValue: newModeValue) ?? .write

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
}

private enum Keys {
    static let language = "MD2.Language"
    static let defaultMode = "MD2.DefaultMode"
    static let newDocumentMode = "MD2.NewDocumentMode"
    static let showsOutlineByDefault = "MD2.ShowsOutlineByDefault"
    static let opensBlankDocumentOnLaunch = "MD2.OpensBlankDocumentOnLaunch"
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

enum L10nKey: String {
    case new
    case open
    case save
    case exportTo
    case exportPDF
    case exportHTML
    case exportDOCX
    case exportEPUB
    case close
    case outline
    case noHeadings
    case hideOutline
    case showOutline
    case mode
    case write
    case read
    case sideBySide
    case writeOrRead
    case writeReadOrSplit
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
    case showOutlineByDefault
    case general
    case preferences
    case unsavedChangesTitle
    case unsavedChangesMessage
    case cancel
    case dontSave
    case find
    case findNext
    case findPrevious
    case findReplace
    case findPlaceholder
    case replace
    case replaceAll
    case closeFind
    case matchStatus
    case noResults
    case print
    case openBlankOnLaunch
    case languageChangedTitle
    case languageChangedMessage
    case restartNow
    case restartLater
    case attachmentFolder
    case attachmentFolderHelp
    case imageNotFound
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
    case citationStyleLabel
    case citationAuthorYear
    case citationNumeric
    case numberAllEquations
    case academicHelp
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

    private static let english: [L10nKey: String] = [
        .new: "New",
        .open: "Open...",
        .save: "Save",
        .exportTo: "Export To",
        .exportPDF: "Export as PDF…",
        .exportHTML: "Export as HTML…",
        .exportDOCX: "Export as DOCX…",
        .exportEPUB: "Export as EPUB…",
        .close: "Close",
        .outline: "Outline",
        .noHeadings: "No headings",
        .hideOutline: "Hide outline",
        .showOutline: "Show outline",
        .mode: "Mode",
        .write: "Edit",
        .read: "Preview",
        .sideBySide: "Side by Side",
        .writeOrRead: "Edit or preview",
        .writeReadOrSplit: "Edit, side by side, or preview",
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
        .showOutlineByDefault: "Show Outline by Default",
        .general: "General",
        .preferences: "Settings",
        .unsavedChangesTitle: "Save changes before closing?",
        .unsavedChangesMessage: "This document has unsaved changes.",
        .cancel: "Cancel",
        .dontSave: "Don't Save",
        .find: "Find…",
        .findNext: "Find Next",
        .findPrevious: "Find Previous",
        .findReplace: "Find and Replace…",
        .findPlaceholder: "Find",
        .replace: "Replace",
        .replaceAll: "Replace All",
        .closeFind: "Close find bar",
        .matchStatus: "%d of %d",
        .noResults: "No results",
        .print: "Print…",
        .openBlankOnLaunch: "Open a blank document on launch",
        .languageChangedTitle: "Restart to apply the new language?",
        .languageChangedMessage: "The menu bar updates to the new language after Markdown2 restarts.",
        .restartNow: "Restart Now",
        .restartLater: "Later",
        .attachmentFolder: "Image Attachment Folder",
        .attachmentFolderHelp: "Screenshots pasted from the clipboard are saved in this document-relative folder. Dragged or pasted image files are linked in place. Defaults to assets.",
        .imageNotFound: "Image not found",
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
        .citationStyleLabel: "Citation Style",
        .citationAuthorYear: "Author-Year",
        .citationNumeric: "Numeric",
        .numberAllEquations: "Number All Equations",
        .academicHelp: "Citations load from a bibliography: front-matter field or a references.bib next to the document."
    ]

    private static let zhHans: [L10nKey: String] = [
        .new: "新建",
        .open: "打开...",
        .save: "保存",
        .exportTo: "导出到",
        .exportPDF: "导出为 PDF…",
        .exportHTML: "导出为 HTML…",
        .exportDOCX: "导出为 DOCX…",
        .exportEPUB: "导出为 EPUB…",
        .close: "关闭",
        .outline: "大纲",
        .noHeadings: "没有标题",
        .hideOutline: "隐藏大纲",
        .showOutline: "显示大纲",
        .mode: "模式",
        .write: "编辑",
        .read: "预览",
        .sideBySide: "双栏",
        .writeOrRead: "编辑或预览",
        .writeReadOrSplit: "编辑、双栏或预览",
        .words: "词",
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
        .showOutlineByDefault: "默认显示大纲",
        .general: "通用",
        .preferences: "设置",
        .unsavedChangesTitle: "关闭前保存更改？",
        .unsavedChangesMessage: "当前文档还有未保存的更改。",
        .cancel: "取消",
        .dontSave: "不保存",
        .find: "查找…",
        .findNext: "查找下一个",
        .findPrevious: "查找上一个",
        .findReplace: "查找与替换…",
        .findPlaceholder: "查找",
        .replace: "替换",
        .replaceAll: "全部替换",
        .closeFind: "关闭查找栏",
        .matchStatus: "第 %d 个，共 %d 个",
        .noResults: "无结果",
        .print: "打印…",
        .openBlankOnLaunch: "启动时打开空白文档",
        .languageChangedTitle: "重启以应用新语言？",
        .languageChangedMessage: "菜单栏将在 Markdown2 重启后切换到新语言。",
        .restartNow: "立即重启",
        .restartLater: "稍后",
        .attachmentFolder: "图片附件文件夹",
        .attachmentFolderHelp: "从剪贴板粘贴的截图会保存到该相对文档的文件夹；拖入或粘贴的图片文件会直接链接原位置。默认为 assets。",
        .imageNotFound: "找不到图片",
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
        .citationStyleLabel: "引用样式",
        .citationAuthorYear: "作者-年份",
        .citationNumeric: "数字编号",
        .numberAllEquations: "为所有公式编号",
        .academicHelp: "引用会从 front-matter 的 bibliography: 字段或文档同目录下的 references.bib 加载。"
    ]
}
