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
}
