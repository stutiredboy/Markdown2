import AppKit
import Foundation

/// Launches and lifecycle stages record a window inventory to the file named by
/// `MD2_HEALTH_FILE`, when that variable is set. Each record starts with the
/// `stage: windows=N visible=M` summary line and is followed by one line per
/// window, so a reader can assert on *which* windows exist and not only how many
/// (the app's window list legitimately contains hidden, non-document windows).
///
/// The GUI guard for the Settings launch presentation is the consumer: it reads
/// these records to prove the Settings window is absent at each stage, and to
/// prove it appears when the user asks for it. This is a silent-failure surface
/// — a window that reappears throws nothing — so the guard asserts on the
/// inventory rather than trusting a clean exit.
enum LaunchHealthReporter {
    /// One window, as the report describes it. `identifier` is empty when the
    /// window has none; SwiftUI's Settings window uses
    /// `com_apple_SwiftUI_Settings_window`.
    struct WindowSnapshot: Equatable {
        var title: String
        var identifier: String
        var className: String
        var isVisible: Bool
    }

    // MARK: - Test seams

    /// Window inventory source. Production reads the live window list; tests
    /// substitute synthetic snapshots so the line format is asserted without
    /// creating real windows.
    @MainActor static var windowSnapshots: () -> [WindowSnapshot] = { liveWindowSnapshots() }

    /// Destination path source. Production reads `MD2_HEALTH_FILE` per call, as
    /// before; tests substitute a temp path (or `nil`, for the no-op contract)
    /// without touching the process environment.
    @MainActor static var healthFilePath: () -> String? = {
        ProcessInfo.processInfo.environment["MD2_HEALTH_FILE"]
    }

    // MARK: - Reporting

    /// Appends one record for `stage`. A no-op when no path is configured —
    /// including reading the window list, which must not happen in normal runs.
    @MainActor
    static func write(_ stage: String) {
        guard let path = healthFilePath() else { return }

        guard let data = line(for: stage, windows: windowSnapshots()).data(using: .utf8) else {
            return
        }

        let url = URL(fileURLWithPath: path)
        if FileManager.default.fileExists(atPath: url.path),
           let handle = try? FileHandle(forWritingTo: url) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }

    @MainActor
    static func liveWindowSnapshots() -> [WindowSnapshot] {
        NSApplication.shared.windows.map { window in
            WindowSnapshot(
                title: window.title,
                identifier: window.identifier?.rawValue ?? "",
                className: "\(type(of: window))",
                isVisible: window.isVisible
            )
        }
    }

    /// The on-disk record. Pure so its shape can be pinned by a unit test: the
    /// GUI guard parses it, and a silent format change would turn the guard's
    /// assertions into vacuous passes.
    static func line(for stage: String, windows: [WindowSnapshot]) -> String {
        var text = "\(stage): windows=\(windows.count) visible=\(windows.filter(\.isVisible).count)\n"
        for window in windows {
            text += "  - title=\(window.title)"
            text += " identifier=\(window.identifier)"
            text += " class=\(window.className)"
            text += " visible=\(window.isVisible)\n"
        }
        return text
    }

    // MARK: - Reading

    /// One stage's inventory, as written by `write(_:)`.
    struct Record: Equatable {
        var stage: String
        var windows: [WindowSnapshot]
    }

    /// Parses what `write(_:)` produced. Strict on purpose: a record is only
    /// returned when its summary line, every window line, and the summary's
    /// counts all agree — so format drift shows up as a *missing* record and
    /// fails the guard that was waiting for it, rather than yielding a record
    /// with no windows whose absence assertions would pass for the wrong reason.
    static func parse(_ text: String) -> [Record] {
        var records: [Record] = []
        var stage: String?
        var declaredTotal = 0
        var declaredVisible = 0
        var windows: [WindowSnapshot] = []

        func flush() {
            if let stage, declaredTotal == windows.count,
               declaredVisible == windows.filter(\.isVisible).count {
                records.append(Record(stage: stage, windows: windows))
            }
            stage = nil
            windows = []
        }

        for line in text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init) {
            if line.hasPrefix("  - ") {
                guard let window = windowSnapshot(from: line) else {
                    stage = nil
                    windows = []
                    continue
                }
                windows.append(window)
                continue
            }

            flush()
            guard let summary = summary(from: line) else { continue }
            stage = summary.stage
            declaredTotal = summary.total
            declaredVisible = summary.visible
        }
        flush()

        return records
    }

    private static func summary(from line: String) -> (stage: String, total: Int, visible: Int)? {
        guard let separator = line.range(of: ": windows=") else { return nil }
        let stage = String(line[line.startIndex..<separator.lowerBound])
        guard !stage.isEmpty, !stage.contains(" ") else { return nil }

        let fields = line[separator.upperBound...].split(separator: " ")
        guard fields.count == 2, fields[1].hasPrefix("visible="),
              let total = Int(fields[0]),
              let visible = Int(fields[1].dropFirst("visible=".count)) else {
            return nil
        }
        return (stage, total, visible)
    }

    private static func windowSnapshot(from line: String) -> WindowSnapshot? {
        let titlePrefix = "  - title="
        guard line.hasPrefix(titlePrefix) else { return nil }
        var remainder = String(line.dropFirst(titlePrefix.count))

        guard let identifierStart = remainder.range(of: " identifier=") else { return nil }
        let title = String(remainder[remainder.startIndex..<identifierStart.lowerBound])
        remainder = String(remainder[identifierStart.upperBound...])

        guard let classStart = remainder.range(of: " class=") else { return nil }
        let identifier = String(remainder[remainder.startIndex..<classStart.lowerBound])
        remainder = String(remainder[classStart.upperBound...])

        guard let visibleStart = remainder.range(of: " visible=") else { return nil }
        let className = String(remainder[remainder.startIndex..<visibleStart.lowerBound])
        let visibleText = String(remainder[visibleStart.upperBound...])

        guard visibleText == "true" || visibleText == "false" else { return nil }
        return WindowSnapshot(
            title: title,
            identifier: identifier,
            className: className,
            isVisible: visibleText == "true"
        )
    }
}
