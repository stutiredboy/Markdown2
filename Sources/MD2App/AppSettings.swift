import Foundation

@MainActor
final class AppSettings: ObservableObject {
    @Published var language: AppLanguage {
        didSet {
            defaults.set(language.rawValue, forKey: Keys.language)
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
}

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case english
    case zhHans

    var id: String {
        rawValue
    }
}

enum L10nKey: String {
    case new
    case open
    case save
    case saveAs
    case exportPDF
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
        .saveAs: "Save As...",
        .exportPDF: "Export as PDF…",
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
        .noResults: "No results"
    ]

    private static let zhHans: [L10nKey: String] = [
        .new: "新建",
        .open: "打开...",
        .save: "保存",
        .saveAs: "另存为...",
        .exportPDF: "导出为 PDF…",
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
        .noResults: "无结果"
    ]
}
