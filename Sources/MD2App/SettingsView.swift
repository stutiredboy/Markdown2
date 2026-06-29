import AppKit
import MD2Core
import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    /// Invoked when the user confirms restarting to apply a language change.
    var onRequestRelaunch: () -> Void = {}
    @State private var recordingShortcutMode: EditorMode?
    @State private var shortcutValidation: ShortcutValidationNotice?

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

                modeShortcutSettings

                Toggle(settings.text(.showOutlineByDefault), isOn: $settings.showsOutlineByDefault)

                Toggle(settings.text(.openBlankOnLaunch), isOn: $settings.opensBlankDocumentOnLaunch)

                VStack(alignment: .leading, spacing: 4) {
                    TextField(settings.text(.attachmentFolder), text: $settings.attachmentFolder)
                        .textFieldStyle(.roundedBorder)
                    Text(settings.text(.attachmentFolderHelp))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section(settings.text(.academic)) {
                Picker(settings.text(.citationStyleLabel), selection: $settings.citationStyle) {
                    Text(settings.text(.citationAuthorYear)).tag(CitationStyle.authorYear)
                    Text(settings.text(.citationNumeric)).tag(CitationStyle.numeric)
                }
                .pickerStyle(.segmented)

                Toggle(settings.text(.numberAllEquations), isOn: $settings.numberAllEquations)

                Text(settings.text(.academicHelp))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ExportSettingsSection(settings: settings)
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

    private var modeShortcutSettings: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(settings.text(.modeShortcuts))
                Spacer()
                Button(settings.text(.resetModeShortcuts)) {
                    settings.resetModeShortcutsToDefaults()
                    recordingShortcutMode = nil
                    shortcutValidation = nil
                }
            }

            ForEach([EditorMode.write, .read, .split]) { mode in
                ModeShortcutRecorderRow(
                    settings: settings,
                    mode: mode,
                    recordingShortcutMode: $recordingShortcutMode,
                    shortcutValidation: $shortcutValidation
                )
            }

            Text(settings.text(.clickToRecordShortcut))
                .font(.caption)
                .foregroundStyle(.secondary)
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

private struct ShortcutValidationNotice: Equatable {
    var mode: EditorMode
    var message: String
}

private struct ModeShortcutRecorderRow: View {
    @ObservedObject var settings: AppSettings
    var mode: EditorMode
    @Binding var recordingShortcutMode: EditorMode?
    @Binding var shortcutValidation: ShortcutValidationNotice?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(settings.modeLabel(mode))
                Spacer()
                Button {
                    recordingShortcutMode = mode
                    shortcutValidation = nil
                } label: {
                    Text(isRecording ? settings.text(.recordingShortcut) : settings.modeShortcuts[mode].displayString)
                        .frame(minWidth: 150)
                }
                .help(settings.text(.clickToRecordShortcut))
                .background(
                    ShortcutCaptureView(isActive: isRecording) { shortcut in
                        if let error = settings.updateModeShortcut(shortcut, for: mode) {
                            shortcutValidation = ShortcutValidationNotice(
                                mode: mode,
                                message: settings.modeShortcutValidationMessage(error)
                            )
                        } else {
                            shortcutValidation = nil
                        }
                        recordingShortcutMode = nil
                    }
                    .frame(width: 0, height: 0)
                )
            }

            if shortcutValidation?.mode == mode, let message = shortcutValidation?.message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private var isRecording: Bool {
        recordingShortcutMode == mode
    }
}

private struct ShortcutCaptureView: NSViewRepresentable {
    var isActive: Bool
    var onShortcut: (ModeKeyboardShortcut) -> Void

    func makeNSView(context: Context) -> ShortcutCaptureNSView {
        let view = ShortcutCaptureNSView()
        view.onShortcut = onShortcut
        return view
    }

    func updateNSView(_ nsView: ShortcutCaptureNSView, context: Context) {
        nsView.isActive = isActive
        nsView.onShortcut = onShortcut
        guard isActive else { return }
        DispatchQueue.main.async {
            nsView.window?.makeFirstResponder(nsView)
        }
    }
}

private final class ShortcutCaptureNSView: NSView {
    var onShortcut: ((ModeKeyboardShortcut) -> Void)?
    var isActive = false

    override var acceptsFirstResponder: Bool {
        true
    }

    override func keyDown(with event: NSEvent) {
        guard isActive else {
            super.keyDown(with: event)
            return
        }
        guard let shortcut = ModeKeyboardShortcut(event: event) else {
            super.keyDown(with: event)
            return
        }
        onShortcut?(shortcut)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isActive else {
            return false
        }
        guard let shortcut = ModeKeyboardShortcut(event: event) else {
            return false
        }
        onShortcut?(shortcut)
        return true
    }
}

/// Export & print configuration: page size, orientation, margins (presets or
/// custom), page numbers, and header/footer text. Edits flow into
/// `settings.exportProfile`, which persists and is applied to every PDF export
/// and Print.
private struct ExportSettingsSection: View {
    @ObservedObject var settings: AppSettings

    /// Picker selection that unifies the margin presets with a synthetic "custom"
    /// entry (the model's `.custom` case has associated values a picker can't tag).
    private enum MarginChoice: Hashable {
        case preset(PageMargins.MarginPreset)
        case custom
    }

    private enum Side { case top, left, bottom, right }

    var body: some View {
        Section(settings.text(.exportSettings)) {
            Picker(settings.text(.pageSizeLabel), selection: $settings.exportProfile.pageSize) {
                Text("A4").tag(PageSize.a4)
                Text("Letter").tag(PageSize.letter)
                Text("Legal").tag(PageSize.legal)
            }
            .pickerStyle(.menu)

            Picker(settings.text(.orientationLabel), selection: $settings.exportProfile.orientation) {
                Text(settings.text(.orientationPortrait)).tag(PageOrientation.portrait)
                Text(settings.text(.orientationLandscape)).tag(PageOrientation.landscape)
            }
            .pickerStyle(.segmented)

            Picker(settings.text(.marginsLabel), selection: marginChoice) {
                Text(settings.text(.marginNarrow)).tag(MarginChoice.preset(.narrow))
                Text(settings.text(.marginNormal)).tag(MarginChoice.preset(.normal))
                Text(settings.text(.marginWide)).tag(MarginChoice.preset(.wide))
                Text(settings.text(.marginNone)).tag(MarginChoice.preset(.none))
                Text(settings.text(.marginCustom)).tag(MarginChoice.custom)
            }
            .pickerStyle(.menu)

            if case .custom = settings.exportProfile.margins {
                customMarginFields
            }

            Toggle(settings.text(.pageNumbers), isOn: $settings.exportProfile.showsPageNumbers)

            if settings.exportProfile.showsPageNumbers {
                Picker(settings.text(.pageNumberPosition), selection: $settings.exportProfile.pageNumberAlignment) {
                    Text(settings.text(.zoneLeft)).tag(PageZone.left)
                    Text(settings.text(.zoneCenter)).tag(PageZone.center)
                    Text(settings.text(.zoneRight)).tag(PageZone.right)
                }
                .pickerStyle(.segmented)
            }

            runningTextRow(
                settings.text(.pageHeader),
                left: $settings.exportProfile.header.left,
                center: $settings.exportProfile.header.center,
                right: $settings.exportProfile.header.right
            )
            runningTextRow(
                settings.text(.pageFooter),
                left: $settings.exportProfile.footer.left,
                center: $settings.exportProfile.footer.center,
                right: $settings.exportProfile.footer.right
            )

            Text(settings.text(.runningTextTokensHelp))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var marginChoice: Binding<MarginChoice> {
        Binding(
            get: {
                switch settings.exportProfile.margins {
                case let .preset(preset): return .preset(preset)
                case .custom: return .custom
                }
            },
            set: { choice in
                switch choice {
                case let .preset(preset):
                    settings.exportProfile.margins = .preset(preset)
                case .custom:
                    // Seed custom values from the current resolved insets so the
                    // switch from a preset is visually continuous.
                    let insets = settings.exportProfile.margins.insets
                    settings.exportProfile.margins = .custom(
                        top: insets.top, left: insets.left,
                        bottom: insets.bottom, right: insets.right
                    )
                }
            }
        )
    }

    private var customMarginFields: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
            GridRow {
                marginField(settings.text(.marginTop), side: .top)
                marginField(settings.text(.marginLeft), side: .left)
            }
            GridRow {
                marginField(settings.text(.marginBottom), side: .bottom)
                marginField(settings.text(.marginRight), side: .right)
            }
        }
    }

    private func marginField(_ label: String, side: Side) -> some View {
        HStack {
            Text(label)
            TextField("", value: marginBinding(side), format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 64)
        }
    }

    private func marginBinding(_ side: Side) -> Binding<Double> {
        Binding(
            get: {
                let insets = settings.exportProfile.margins.insets
                switch side {
                case .top: return Double(insets.top)
                case .left: return Double(insets.left)
                case .bottom: return Double(insets.bottom)
                case .right: return Double(insets.right)
                }
            },
            set: { newValue in
                var insets = settings.exportProfile.margins.insets
                let clamped = CGFloat(max(0, newValue))
                switch side {
                case .top: insets.top = clamped
                case .left: insets.left = clamped
                case .bottom: insets.bottom = clamped
                case .right: insets.right = clamped
                }
                settings.exportProfile.margins = .custom(
                    top: insets.top, left: insets.left,
                    bottom: insets.bottom, right: insets.right
                )
            }
        )
    }

    private func runningTextRow(
        _ label: String,
        left: Binding<String>,
        center: Binding<String>,
        right: Binding<String>
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.subheadline)
            HStack(spacing: 6) {
                TextField(settings.text(.zoneLeft), text: left).textFieldStyle(.roundedBorder)
                TextField(settings.text(.zoneCenter), text: center).textFieldStyle(.roundedBorder)
                TextField(settings.text(.zoneRight), text: right).textFieldStyle(.roundedBorder)
            }
        }
    }
}
