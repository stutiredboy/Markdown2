import Foundation
import Testing
@testable import MD2App

/// Non-GUI coverage for the launch health probe. The GUI guard for the Settings
/// launch presentation parses these records, so the record shape is pinned here:
/// a silent format change would turn that guard's absence assertions into
/// vacuous passes.
struct LaunchHealthReporterTests {
    @Test func recordDescribesEveryWindowWithAllFourFields() {
        let windows = [
            LaunchHealthReporter.WindowSnapshot(
                title: "Sample.md",
                identifier: "",
                className: "ModeShortcutWindow",
                isVisible: true
            ),
            LaunchHealthReporter.WindowSnapshot(
                title: "Markdown2 设置",
                identifier: "com_apple_SwiftUI_Settings_window",
                className: "AppKitWindow",
                isVisible: true
            ),
            LaunchHealthReporter.WindowSnapshot(
                title: "",
                identifier: "",
                className: "TUINSWindow",
                isVisible: false
            )
        ]

        let record = LaunchHealthReporter.line(for: "didFinishLaunching", windows: windows)

        #expect(record == """
        didFinishLaunching: windows=3 visible=2
          - title=Sample.md identifier= class=ModeShortcutWindow visible=true
          - title=Markdown2 设置 identifier=com_apple_SwiftUI_Settings_window class=AppKitWindow visible=true
          - title= identifier= class=TUINSWindow visible=false

        """)
    }

    @Test func recordOfAnEmptyWindowListIsJustTheSummary() {
        let record = LaunchHealthReporter.line(for: "reopen", windows: [])

        #expect(record == "reopen: windows=0 visible=0\n")
    }

    @Test func parseRoundTripsWhatLineWrote() {
        let windows = [
            LaunchHealthReporter.WindowSnapshot(
                title: "Sample.md",
                identifier: "",
                className: "ModeShortcutWindow",
                isVisible: true
            ),
            LaunchHealthReporter.WindowSnapshot(
                title: "Markdown2 设置",
                identifier: "com_apple_SwiftUI_Settings_window",
                className: "AppKitWindow",
                isVisible: true
            )
        ]

        let records = LaunchHealthReporter.parse(
            LaunchHealthReporter.line(for: "didFinishLaunching", windows: windows)
                + LaunchHealthReporter.line(for: "reopen", windows: [])
        )

        #expect(records == [
            LaunchHealthReporter.Record(stage: "didFinishLaunching", windows: windows),
            LaunchHealthReporter.Record(stage: "reopen", windows: [])
        ])
    }

    /// Format drift has to surface as a missing record, not as a record with no
    /// windows: the guard's absence assertions would pass on the latter.
    @Test func parseDropsRecordsWhoseCountsDisagreeWithTheirWindows() {
        let drifted = """
        didFinishLaunching: windows=2 visible=2
          - title=Sample.md identifier= class=ModeShortcutWindow visible=true

        """

        #expect(LaunchHealthReporter.parse(drifted).isEmpty)
        #expect(LaunchHealthReporter.parse("not a record at all\n").isEmpty)
    }

    /// The probe has to stay invisible in normal runs: with no path configured it
    /// must not consult the window list at all.
    @Test @MainActor func writeConsultsNothingWhenNoPathIsConfigured() {
        let originalPath = LaunchHealthReporter.healthFilePath
        let originalSnapshots = LaunchHealthReporter.windowSnapshots
        defer {
            LaunchHealthReporter.healthFilePath = originalPath
            LaunchHealthReporter.windowSnapshots = originalSnapshots
        }

        var didReadWindows = false
        LaunchHealthReporter.healthFilePath = { nil }
        LaunchHealthReporter.windowSnapshots = {
            didReadWindows = true
            return []
        }

        LaunchHealthReporter.write("didFinishLaunching")

        #expect(didReadWindows == false)
    }

    /// Records append, one per stage: the guard polls the file and needs the
    /// evidence for each stage it waits on to survive later writes.
    @Test @MainActor func writeAppendsOneRecordPerStage() throws {
        let healthFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("LaunchHealthReporterTests-\(UUID().uuidString).txt")
        let originalPath = LaunchHealthReporter.healthFilePath
        let originalSnapshots = LaunchHealthReporter.windowSnapshots
        defer {
            LaunchHealthReporter.healthFilePath = originalPath
            LaunchHealthReporter.windowSnapshots = originalSnapshots
            try? FileManager.default.removeItem(at: healthFileURL)
        }

        LaunchHealthReporter.healthFilePath = { healthFileURL.path }
        LaunchHealthReporter.windowSnapshots = {
            [
                LaunchHealthReporter.WindowSnapshot(
                    title: "Markdown2 Settings",
                    identifier: "com_apple_SwiftUI_Settings_window",
                    className: "AppKitWindow",
                    isVisible: true
                )
            ]
        }

        LaunchHealthReporter.write("didFinishLaunching")
        LaunchHealthReporter.write("reopen")

        let contents = try String(contentsOf: healthFileURL, encoding: .utf8)
        #expect(contents == """
        didFinishLaunching: windows=1 visible=1
          - title=Markdown2 Settings identifier=com_apple_SwiftUI_Settings_window class=AppKitWindow visible=true
        reopen: windows=1 visible=1
          - title=Markdown2 Settings identifier=com_apple_SwiftUI_Settings_window class=AppKitWindow visible=true

        """)
    }
}
