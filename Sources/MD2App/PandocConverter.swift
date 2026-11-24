import Foundation
import Darwin
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
    func cancel()
    func convert(
        markdown: String,
        format: DocumentExportFormat,
        resourceDirectory: URL?,
        destination: URL,
        completion: @escaping (Result<Void, Error>) -> Void
    )
}

extension DocumentConverting {
    // Test adapters that synchronously complete have no work to cancel.
    func cancel() {}
}

/// Produces DOCX/EPUB by invoking an external, user-installed Pandoc binary on the
/// document's current Markdown. The native pipeline stays dependency-free: Pandoc
/// is optional, detected at use time, and degrades gracefully when absent.
///
/// The current Markdown is staged privately. Pandoc resolves relative resources
/// from the document directory, or from the private temporary directory for
/// untitled documents. Only the completed archive reaches the chosen destination.
@MainActor
final class PandocConverter: DocumentConverting {
    enum ConversionError: LocalizedError, Sendable {
        case pandocNotFound
        case preparationFailed
        case conversionFailed(String)
        case destinationChanged
        case timedOut
        case confinementUnavailable
        case canceled

        var errorDescription: String? {
            detail { L10n.text($0, language: .english) }
        }

        func detail(using text: (L10nKey) -> String) -> String {
            switch self {
            case .pandocNotFound:
                return text(.alertPandocRequiredDetail)
            case .preparationFailed:
                return text(.conversionPreparationFailed)
            case .conversionFailed(let detail):
                let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return text(.conversionFailed) }
                let excerpt = trimmed.prefix(600)
                let display = excerpt.count < trimmed.count ? String(excerpt) + "…" : String(excerpt)
                return String(format: text(.conversionFailedWithDetail), display)
            case .destinationChanged:
                return text(.conversionDestinationChanged)
            case .confinementUnavailable:
                return text(.conversionConfinementUnavailable)
            case .canceled:
                return text(.conversionCanceled)
            case .timedOut:
                return text(.conversionTimedOut)
            }
        }
    }

    /// Maximum time to allow a single Pandoc invocation before terminating it.
    private nonisolated static let timeout: TimeInterval = 60
    private nonisolated static let archiveInspector = URL(fileURLWithPath: "/usr/bin/unzip")
    private nonisolated static let archiveWriter = URL(fileURLWithPath: "/usr/bin/zip")
    private let locatePandoc: () -> URL?

    /// Completion held for the conversion's asynchronous lifetime, called on the
    /// main actor exactly once. Storing it (rather than capturing it in the
    /// background closure) keeps the main-actor completion off the worker thread.
    private var pendingCompletion: ((Result<Void, Error>) -> Void)?
    private var pendingJob: PandocConversionJob?

    init(locatePandoc: @escaping () -> URL? = { PandocConverter.pandocURL() }) {
        self.locatePandoc = locatePandoc
    }

    func convert(
        markdown: String,
        format: DocumentExportFormat,
        resourceDirectory: URL?,
        destination: URL,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        guard pendingJob == nil else { return }
        guard FileManager.default.isExecutableFile(atPath: OfflinePandocProcess.sandboxURL.path) else {
            completion(.failure(ConversionError.confinementUnavailable))
            return
        }
        guard let pandoc = locatePandoc() else {
            completion(.failure(ConversionError.pandocNotFound))
            return
        }
        guard let expectedDestination = DestinationState(at: destination) else {
            completion(.failure(ConversionError.preparationFailed))
            return
        }

        let job = PandocConversionJob()
        pendingJob = job
        pendingCompletion = completion
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = Self.stageConversion(markdown: markdown, format: format,
                resourceDirectory: resourceDirectory, destination: destination, pandoc: pandoc, job: job)
            Task { @MainActor in
                defer {
                    if case .success(let staged) = outcome {
                        try? FileManager.default.removeItem(at: staged.deletingLastPathComponent())
                    }
                }
                guard self.pendingJob === job, !job.isCanceled else { return }
                switch outcome {
                case .success(let staged):
                    self.finish(expectedDestination.publish(staged, to: destination))
                case .failure(let error):
                    self.finish(error)
                }
            }
        }
    }

    private nonisolated static func stageConversion(
        markdown: String, format: DocumentExportFormat, resourceDirectory: URL?, destination: URL,
        pandoc: URL, job: PandocConversionJob
    ) -> Result<URL, ConversionError> {
        guard !job.isCanceled else { return .failure(.canceled) }
        let reader: String
        switch readerFormat(for: pandoc, job: job) {
        case .success(let format): reader = format
        case .failure(let error): return .failure(conversionError(error))
        }

        let manager = FileManager.default
        let inputDirectory = manager.temporaryDirectory.appendingPathComponent("md2-export-\(UUID())",
                                                                               isDirectory: true)
        let stagingDirectory = destination.deletingLastPathComponent()
            .appendingPathComponent(".md2-converted-\(UUID())", isDirectory: true)
        let directoryPermissions: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
        do {
            try manager.createDirectory(at: inputDirectory, withIntermediateDirectories: false,
                                        attributes: directoryPermissions)
            defer { try? manager.removeItem(at: inputDirectory) }
            let input = inputDirectory.appendingPathComponent("document.md")
            try markdown.write(to: input, atomically: false, encoding: .utf8)
            let workingDirectory = resourceDirectory ?? inputDirectory
            let citations = citationArguments(markdown: markdown, resourceDirectory: workingDirectory)
            guard !job.isCanceled else { return .failure(.canceled) }

            try manager.createDirectory(at: stagingDirectory, withIntermediateDirectories: false,
                                        attributes: directoryPermissions)
            var completed = false
            defer {
                if !completed { try? manager.removeItem(at: stagingDirectory) }
            }
            let staged = stagingDirectory.appendingPathComponent("document.\(format.fileExtension)")
            switch OfflinePandocProcess.run(pandoc: pandoc, arguments: [input.path, "--from", reader, "-o", staged.path]
                                             + citations, directory: workingDirectory, timeout: timeout, job: job) {
            case .failure(let error): return .failure(conversionError(error))
            case .success:
                guard hasZipHeader(staged) else { return .failure(.conversionFailed("")) }
                if format == .docx, let error = addDocxTableGrid(to: staged, in: inputDirectory, job: job) {
                    return .failure(error)
                }
                // Inspect the central directory without extracting or inflating
                // any more entries. A partial archive can still start with PK.
                if case .failure(let error) = OfflinePandocProcess.run(pandoc: archiveInspector,
                    arguments: ["-Zt", staged.path], directory: nil, timeout: 5, job: job) {
                    return .failure(conversionError(error))
                }
                completed = true
                return .success(staged)
            }
        } catch {
            return .failure(.preparationFailed)
        }
    }

    private nonisolated static func addDocxTableGrid(
        to archive: URL, in inputDirectory: URL, job: PandocConversionJob
    ) -> ConversionError? {
        let parts = DocxTableBorders.Part.allCases
        let entries: Set<Substring>
        switch OfflinePandocProcess.run(pandoc: archiveInspector,
            arguments: ["-Z1", archive.path] + parts.map(\.path), directory: nil, timeout: 5, job: job) {
        case .success(let output): entries = Set(output.split(whereSeparator: \.isNewline))
        case .failure(let error): return conversionError(error)
        }
        guard entries.contains(Substring(DocxTableBorders.Part.document.path)) else { return .conversionFailed("") }

        do {
            try FileManager.default.createDirectory(at: inputDirectory.appendingPathComponent("word"),
                                                     withIntermediateDirectories: false)
            var updatedPaths: [String] = []
            for part in parts where entries.contains(Substring(part.path)) {
                let document = inputDirectory.appendingPathComponent(part.path)
                try Data().write(to: document)
                let handle = try FileHandle(forWritingTo: document)
                defer { try? handle.close() }
                // Inflate only the selected XML into our private directory,
                // bypassing the size limit for captured diagnostics.
                if case .failure(let error) = OfflinePandocProcess.run(pandoc: archiveInspector,
                    arguments: ["-p", archive.path, part.path], directory: nil, timeout: 5,
                    job: job, standardOutput: handle) {
                    return conversionError(error)
                }
                guard !job.isCanceled else { return .canceled }
                let xml = try Data(contentsOf: document)
                guard let updated = try DocxTableBorders.addingGrid(to: xml, part: part) else { continue }
                try updated.write(to: document, options: .atomic)
                updatedPaths.append(part.path)
            }
            guard !updatedPaths.isEmpty else { return nil }
            if case .failure(let error) = OfflinePandocProcess.run(pandoc: archiveWriter,
                arguments: ["-q", "-X", archive.path] + updatedPaths, directory: inputDirectory, timeout: timeout,
                job: job) {
                return conversionError(error)
            }
            return nil
        } catch {
            return .conversionFailed(error.localizedDescription)
        }
    }

    private nonisolated static func hasZipHeader(_ url: URL) -> Bool {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return false }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var entry = stat()
        guard fstat(descriptor, &entry) == 0, entry.st_mode & S_IFMT == S_IFREG else { return false }
        return (try? handle.read(upToCount: 4)) == Data([0x50, 0x4B, 0x03, 0x04])
    }

    func cancel() {
        guard let job = pendingJob else { return }
        job.cancel()
        finish(.canceled)
    }

    private func finish(_ failure: ConversionError?) {
        let completion = pendingCompletion
        pendingCompletion = nil
        pendingJob = nil
        if let failure { completion?(.failure(failure)) }
        else { completion?(.success(())) }
    }

    private nonisolated static func conversionError(_ error: OfflinePandocProcess.Failure) -> ConversionError {
        switch error {
        case .confinementUnavailable: .confinementUnavailable
        case .launchFailed(let detail), .failed(let detail): .conversionFailed(detail)
        case .timedOut: .timedOut
        case .canceled: .canceled
        }
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

    // MARK: - Detection

    /// Finder launches usually have a minimal PATH. Check common locations
    /// first, then absolute PATH directories. Search again on each export so an
    /// installation or upgrade is visible from the running app.
    nonisolated static func pandocURL(
        standardDirectories: [String] = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"],
        searchPath: String = ProcessInfo.processInfo.environment["PATH"] ?? ""
    ) -> URL? {
        let directories = standardDirectories + searchPath.split(separator: ":").map(String.init)
        for directory in directories where directory.hasPrefix("/") {
            let url = URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent("pandoc")
            var entry = stat()
            if stat(url.path, &entry) == 0, entry.st_mode & S_IFMT == S_IFREG,
               FileManager.default.isExecutableFile(atPath: url.path) {
                return url
            }
        }
        return nil
    }

    nonisolated static func isAvailable() -> Bool { pandocURL() != nil }

    // MARK: - Reader format (gfm on Pandoc 2.0+, markdown_github on older)

    /// The GitHub-flavored Markdown reader to pass to Pandoc: the canonical `gfm`
    /// on Pandoc 2.0+, falling back to the deprecated `markdown_github` alias only
    /// on older 1.x builds that do not know `gfm`. Probe the selected executable
    /// so a new installation or upgrade can change the reader immediately.
    nonisolated static func readerFormat(for pandoc: URL, job: PandocConversionJob = .init())
        -> Result<String, OfflinePandocProcess.Failure> {
        // A rejected confinement/version probe is an error to the converter,
        // never an excuse to run the conversion executable without its wrapper.
        switch OfflinePandocProcess.run(pandoc: pandoc, arguments: ["--version"],
                                        directory: nil, timeout: 5, job: job) {
        case .success(let output):
            return .success(reader(forMajorVersion: parseMajorVersion(fromVersionOutput: output)))
        case .failure(let error): return .failure(error)
        }
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

}

private enum DestinationState: Equatable {
    struct FileState: Equatable {
        let device: dev_t
        let inode: ino_t
        let size: off_t
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int
        let changedSeconds: Int
        let changedNanoseconds: Int
    }

    case missing
    case existing(FileState)

    init?(at url: URL) {
        var entry = stat()
        if lstat(url.path, &entry) != 0 {
            guard errno == ENOENT else { return nil }
            self = .missing
            return
        }
        guard entry.st_mode & S_IFMT == S_IFREG else { return nil }
        self = .existing(FileState(device: entry.st_dev, inode: entry.st_ino, size: entry.st_size,
                                   modifiedSeconds: entry.st_mtimespec.tv_sec,
                                   modifiedNanoseconds: entry.st_mtimespec.tv_nsec,
                                   changedSeconds: entry.st_ctimespec.tv_sec,
                                   changedNanoseconds: entry.st_ctimespec.tv_nsec))
    }

    func publish(_ staged: URL, to destination: URL) -> PandocConverter.ConversionError? {
        switch self {
        case .missing:
            if renamex_np(staged.path, destination.path, UInt32(RENAME_EXCL)) == 0 { return nil }
            return errno == EEXIST ? .destinationChanged : .preparationFailed
        case .existing:
            guard DestinationState(at: destination) == self else { return .destinationChanged }
            return rename(staged.path, destination.path) == 0 ? nil : .preparationFailed
        }
    }
}
