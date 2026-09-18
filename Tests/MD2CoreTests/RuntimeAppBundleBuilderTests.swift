import Foundation
import Testing
@testable import MD2App

struct RuntimeAppBundleBuilderTests {
    @Test func relaunchArgumentsConvertRelativeDocumentPathsToAbsolute() {
        let arguments = DirectLaunchBootstrap.normalizedRelaunchArguments(
            ["--ignored-flag", "Examples/Sample.md"],
            currentDirectoryPath: "/tmp/Markdown2"
        )

        #expect(arguments == ["--ignored-flag", "/tmp/Markdown2/Examples/Sample.md"])
    }

    @Test func relaunchArgumentsPreserveAbsoluteDocumentPaths() {
        let arguments = DirectLaunchBootstrap.normalizedRelaunchArguments(
            ["/Users/example/Notes.md"],
            currentDirectoryPath: "/tmp/Markdown2"
        )

        #expect(arguments == ["/Users/example/Notes.md"])
    }

    @Test func buildCopiesCompanionResourceBundles() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("RuntimeAppBundleBuilderTests-\(UUID().uuidString)", isDirectory: true)
        let productDirectory = root.appendingPathComponent("Products", isDirectory: true)
        let executableURL = productDirectory.appendingPathComponent("Markdown2")
        let bundleURL = productDirectory.appendingPathComponent("MD2_MD2Core.bundle", isDirectory: true)
        let bundleMarkerURL = bundleURL.appendingPathComponent("marker.txt")
        let appURL = root.appendingPathComponent("Markdown2.app", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        try fileManager.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        try "binary".write(to: executableURL, atomically: true, encoding: .utf8)
        try "resource".write(to: bundleMarkerURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)

        try RuntimeAppBundleBuilder().build(bundleURL: appURL, executableURL: executableURL)

        let copiedMarkerURL = appURL
            .appendingPathComponent("Contents/Resources/MD2_MD2Core.bundle", isDirectory: true)
            .appendingPathComponent("marker.txt")
        #expect(fileManager.fileExists(atPath: copiedMarkerURL.path))
    }

    /// The macOS 15 floor is half of the Settings-window fix (the launch
    /// presentation opt-out is a macOS 15 API), and this generated plist is what
    /// the dev build actually runs under — `Scripts/package_app.sh` owns the
    /// release copy, which this test cannot see.
    @Test func buildDeclaresMacOS15MinimumSystemVersion() throws {
        let (appURL, root) = try makeAppBundle()
        defer { try? FileManager.default.removeItem(at: root) }

        let plist = try readInfoPlist(at: appURL)
        #expect(plist["LSMinimumSystemVersion"] as? String == "15.0")
    }

    @Test func buildKeepsDefaultBundleIdentifier() throws {
        let (appURL, root) = try makeAppBundle()
        defer { try? FileManager.default.removeItem(at: root) }

        let plist = try readInfoPlist(at: appURL)
        #expect(plist["CFBundleIdentifier"] as? String == "dev.codex.md2.debug")
    }

    /// The GUI guard launches a real app under a test-only identity so it never
    /// touches the developer's own preferences domain; this is the seam it uses.
    @Test func buildUsesSuppliedBundleIdentifier() throws {
        let (appURL, root) = try makeAppBundle(bundleIdentifier: "dev.codex.md2.gui-guard")
        defer { try? FileManager.default.removeItem(at: root) }

        let plist = try readInfoPlist(at: appURL)
        #expect(plist["CFBundleIdentifier"] as? String == "dev.codex.md2.gui-guard")
    }

    private func makeAppBundle(
        bundleIdentifier: String = "dev.codex.md2.debug"
    ) throws -> (appURL: URL, root: URL) {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("RuntimeAppBundleBuilderTests-\(UUID().uuidString)", isDirectory: true)
        let productDirectory = root.appendingPathComponent("Products", isDirectory: true)
        let executableURL = productDirectory.appendingPathComponent("Markdown2")
        let appURL = root.appendingPathComponent("Markdown2.app", isDirectory: true)

        try fileManager.createDirectory(at: productDirectory, withIntermediateDirectories: true)
        try "binary".write(to: executableURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)

        try RuntimeAppBundleBuilder(bundleIdentifier: bundleIdentifier)
            .build(bundleURL: appURL, executableURL: executableURL)

        return (appURL, root)
    }

    private func readInfoPlist(at appURL: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: appURL.appendingPathComponent("Contents/Info.plist"))
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try #require(plist as? [String: Any])
    }
}
