import Foundation
import MD2Core

/// Output formats produced by delegating to an external Pandoc binary.
enum DocumentExportFormat: Sendable {
    case docx
    case epub

    var fileExtension: String {
        switch self {
        case .docx: return "docx"
        case .epub: return "epub"
        }
    }
}

/// Converts a document's Markdown source to another format. Injected behind this
/// protocol so the export flow is testable without a real Pandoc binary.
@MainActor
protocol DocumentConverting: AnyObject {
    func convert(
        markdown: String,
        format: DocumentExportFormat,
        resourceDirectory: URL,
        destination: URL,
        completion: @escaping (Result<Void, Error>) -> Void
    )
}

/// Produces DOCX/EPUB by invoking an external, user-installed Pandoc binary on the
/// document's current Markdown. The native pipeline stays dependency-free: Pandoc
/// is optional, detected at use time, and degrades gracefully when absent.
///
/// The Markdown is written to a temporary file inside the document directory and
/// Pandoc runs with that directory as its working directory, so relative images
/// resolve (without the 2.0-only `--resource-path`) and unsaved edits are captured
/// without touching the saved file. The run is bounded by a timeout; on timeout or
/// a non-zero exit the partial output is removed and an error is reported.
@MainActor
final class PandocConverter: DocumentConverting {
    enum ConversionError: LocalizedError, Sendable {
        case pandocNotFound
        case preparationFailed
        case conversionFailed(String)
        case timedOut

        var errorDescription: String? {
            switch self {
            case .pandocNotFound:
                return "Pandoc is required to export DOCX/EPUB but was not found. Install Pandoc and try again."
            case .preparationFailed:
                return "The document could not be prepared for conversion."
            case .conversionFailed(let detail):
                let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? "Pandoc could not convert the document." : "Pandoc failed: \(trimmed)"
            case .timedOut:
                return "The conversion took too long and was stopped."
            }
        }
    }

    /// Filename prefix for the temporary Markdown written next to the document.
    private nonisolated static let tempPrefix = ".md2-export-"
    /// Maximum time to allow a single Pandoc invocation before terminating it.
    private nonisolated static let timeout: TimeInterval = 60

    /// Completion held for the conversion's asynchronous lifetime, called on the
    /// main actor exactly once. Storing it (rather than capturing it in the
    /// background closure) keeps the main-actor completion off the worker thread.
    private var pendingCompletion: ((Result<Void, Error>) -> Void)?

    func convert(
        markdown: String,
        format: DocumentExportFormat,
        resourceDirectory: URL,
        destination: URL,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        guard let pandoc = Self.pandocURL() else {
            completion(.failure(ConversionError.pandocNotFound))
            return
        }

        // Write the current Markdown to a temp file in the document directory so
        // relative images resolve from the working directory and unsaved edits are
        // captured without mutating the saved file.
        let tempURL = resourceDirectory.appendingPathComponent("\(Self.tempPrefix)\(UUID().uuidString).md")
        do {
            try markdown.write(to: tempURL, atomically: true, encoding: .utf8)
        } catch {
            completion(.failure(ConversionError.preparationFailed))
            return
        }

        // Formal citation processing: enable `--citeproc` and point Pandoc at the
        // associated `.bib` so `[@key]` citations get full CSL formatting.
        let citationArguments = Self.citationArguments(markdown: markdown, resourceDirectory: resourceDirectory)

        pendingCompletion = completion
        // Run the blocking Pandoc invocation off the main actor; only a `Sendable`
        // outcome crosses back to the main actor to fire the completion.
        DispatchQueue.global(qos: .userInitiated).async {
            let failure = Self.runPandoc(
                pandoc: pandoc,
                input: tempURL,
                workingDirectory: resourceDirectory,
                destination: destination,
                extraArguments: citationArguments
            )
            try? FileManager.default.removeItem(at: tempURL)
            if failure != nil {
                // Never leave a partial/corrupt output file presented as success.
                try? FileManager.default.removeItem(at: destination)
            }
            Task { @MainActor in
                self.finish(failure)
            }
        }
    }

    private func finish(_ failure: ConversionError?) {
        let completion = pendingCompletion
        pendingCompletion = nil
        if let failure {
            completion?(.failure(failure))
        } else {
            completion?(.success(()))
        }
    }

    /// Runs Pandoc synchronously (on a background queue) with a watchdog timeout.
    /// Returns `nil` on success, or the failure reason.
    private nonisolated static func runPandoc(
        pandoc: URL,
        input: URL,
        workingDirectory: URL,
        destination: URL,
        extraArguments: [String] = []
    ) -> ConversionError? {
        let process = Process()
        process.executableURL = pandoc
        process.currentDirectoryURL = workingDirectory
        // Input by name (relative to the working directory) so relative image
        // paths resolve; writer inferred from the output extension.
        process.arguments = [
            input.lastPathComponent,
            "--from", Self.readerFormat(for: pandoc),
            "-o", destination.path
        ] + extraArguments
        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = Pipe()

        do {
            try process.run()
        } catch {
            return .conversionFailed(error.localizedDescription)
        }

        let timeoutLock = NSLock()
        var didTimeOut = false
        let watchdog = DispatchWorkItem {
            timeoutLock.lock()
            didTimeOut = true
            timeoutLock.unlock()
            process.terminate()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.timeout, execute: watchdog)

        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()

        timeoutLock.lock()
        let timedOut = didTimeOut
        timeoutLock.unlock()

        if timedOut {
            return .timedOut
        }
        guard process.terminationStatus == 0 else {
            let message = String(data: errorData, encoding: .utf8) ?? ""
            return .conversionFailed(message)
        }
        return nil
    }

    /// Pandoc arguments for formal citation processing. When a bibliography is
    /// associated — the front-matter `bibliography:` field (which Pandoc reads
    /// itself) or an auto-detected `references.bib` next to the document — returns
    /// `--citeproc` plus, for the auto-detected case, an explicit `--bibliography`.
    /// A front-matter `csl:` style is forwarded as `--csl`. Returns no arguments
    /// when no bibliography is found, so a citation-free document is unaffected.
    nonisolated static func citationArguments(markdown: String, resourceDirectory: URL) -> [String] {
        let fields = FrontMatterReader.fields(in: markdown)
        var arguments: [String] = []
        var hasBibliography = false

        if let path = fields["bibliography"],
           FileManager.default.fileExists(atPath: resourceDirectory.appendingPathComponent(path).path) {
            // Pandoc resolves the front-matter `bibliography:` field itself.
            hasBibliography = true
        } else if FileManager.default.fileExists(
            atPath: resourceDirectory.appendingPathComponent("references.bib").path
        ) {
            arguments.append("--bibliography=references.bib")
            hasBibliography = true
        }

        guard hasBibliography else { return [] }
        arguments.insert("--citeproc", at: 0)
        if let csl = fields["csl"] {
            arguments.append("--csl=\(csl)")
        }
        return arguments
    }

    // MARK: - Detection (cached, refreshable)

    private nonisolated static let cacheLock = NSLock()
    private nonisolated(unsafe) static var cachedURL: URL?
    private nonisolated(unsafe) static var cachedAt: Date?
    private nonisolated static let cacheTTL: TimeInterval = 60

    /// Locates the Pandoc binary, caching the result briefly so repeated menu/UI
    /// checks are cheap. `forceRefresh` re-checks immediately (e.g. when the app is
    /// re-activated after the user may have installed Pandoc).
    nonisolated static func pandocURL(forceRefresh: Bool = false) -> URL? {
        cacheLock.lock()
        defer { cacheLock.unlock() }

        if !forceRefresh, let cachedAt, Date().timeIntervalSince(cachedAt) < cacheTTL {
            return cachedURL
        }
        let located = locatePandoc()
        cachedURL = located
        cachedAt = Date()
        return located
    }

    nonisolated static func isAvailable(forceRefresh: Bool = false) -> Bool {
        pandocURL(forceRefresh: forceRefresh) != nil
    }

    /// Searches common install locations first (a Finder-launched app has a minimal
    /// `PATH`), then any directories on `PATH`.
    private nonisolated static func locatePandoc() -> URL? {
        let candidates = [
            "/opt/homebrew/bin/pandoc",
            "/usr/local/bin/pandoc",
            "/usr/bin/pandoc"
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }

        if let pathEnv = ProcessInfo.processInfo.environment["PATH"] {
            for directory in pathEnv.split(separator: ":") {
                let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent("pandoc")
                if FileManager.default.isExecutableFile(atPath: candidate.path) {
                    return candidate
                }
            }
        }
        return nil
    }

    // MARK: - Reader format (gfm on Pandoc 2.0+, markdown_github on older)

    private nonisolated(unsafe) static var cachedReader: String?

    /// The GitHub-flavored Markdown reader to pass to Pandoc: the canonical `gfm`
    /// on Pandoc 2.0+, falling back to the deprecated `markdown_github` alias only
    /// on older 1.x builds that do not know `gfm`. Determined once (via
    /// `pandoc --version`) and cached for the process lifetime.
    nonisolated static func readerFormat(for pandoc: URL) -> String {
        cacheLock.lock()
        if let cachedReader {
            cacheLock.unlock()
            return cachedReader
        }
        cacheLock.unlock()

        let reader = reader(forMajorVersion: pandocMajorVersion(of: pandoc))
        cacheLock.lock()
        cachedReader = reader
        cacheLock.unlock()
        return reader
    }

    /// Pure mapping from a detected major version to the reader name. An unknown
    /// version (nil) uses the compatible alias so conversion never breaks.
    nonisolated static func reader(forMajorVersion major: Int?) -> String {
        (major ?? 0) >= 2 ? "gfm" : "markdown_github"
    }

    /// Pure parse of Pandoc's `--version` output, whose first line is like
    /// `pandoc 3.1.9` (or `pandoc 1.13.2`). Returns the major version, or nil.
    nonisolated static func parseMajorVersion(fromVersionOutput output: String) -> Int? {
        guard let firstLine = output.split(separator: "\n").first else { return nil }
        let tokens = firstLine.split(separator: " ", omittingEmptySubsequences: true)
        guard tokens.count >= 2,
              let majorToken = tokens[1].split(separator: ".").first,
              let major = Int(majorToken) else {
            return nil
        }
        return major
    }

    private nonisolated static func pandocMajorVersion(of pandoc: URL) -> Int? {
        let process = Process()
        process.executableURL = pandoc
        process.arguments = ["--version"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let output = String(data: data, encoding: .utf8) else { return nil }
        return parseMajorVersion(fromVersionOutput: output)
    }
}
