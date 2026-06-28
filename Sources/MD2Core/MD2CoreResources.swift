import Foundation

/// Resolves the MD2Core resource bundle (the bundled KaTeX and diagram assets)
/// across every way this code runs: `swift test`, the debug self-bootstrapped
/// app bundle, and the packaged, code-signed `/Applications/Markdown2.app`.
///
/// SwiftPM's generated `Bundle.module` accessor only looks for the resource
/// bundle at the **app bundle root** (`Bundle.main.bundleURL/<name>.bundle`) or
/// at a hard-coded build-machine path. The app-root location cannot be
/// code-signed: macOS rejects any item sitting beside `Contents/` as "unsealed
/// contents present in the bundle root", which invalidates the bundle signature
/// and makes the packaged app get killed by AMFI on launch (`Killed: 9`, no
/// crash report). The packaged `.app` therefore ships the resource bundle inside
/// `Contents/Resources` — a sealed, signable location — and we resolve it from
/// there first, only falling back to `Bundle.module` for non-bundled runs such
/// as `swift test`.
enum MD2CoreResources {
    /// The resolved bundle that carries the `katex` and `diagrams` subdirectories.
    static let bundle: Bundle = resolve()

    private static func resolve() -> Bundle {
        if let resourceURL = Bundle.main.resourceURL,
           let bundled = resourceBundle(in: resourceURL) {
            return bundled
        }
        return Bundle.module
    }

    /// Returns the first `*.bundle` in `directory` that actually carries the
    /// MD2Core assets (identified by a `katex` subdirectory), so an unrelated
    /// resource bundle is never mistaken for ours.
    private static func resourceBundle(in directory: URL) -> Bundle? {
        let fileManager = FileManager.default
        let entries = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []

        for entry in entries where entry.pathExtension == "bundle" {
            let marker = entry.appendingPathComponent("katex", isDirectory: true)
            if fileManager.fileExists(atPath: marker.path),
               let bundle = Bundle(url: entry) {
                return bundle
            }
        }
        return nil
    }
}
