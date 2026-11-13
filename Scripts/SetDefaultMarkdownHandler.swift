import AppKit
import Foundation
import UniformTypeIdentifiers

private struct HandlerFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

// NSWorkspace does not promise a completion queue. The command-line caller
// keeps its main run loop available while this lock protects the reply.
private final class HandlerReply: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Void, Error>?

    func complete(_ error: Error?) {
        lock.lock()
        defer { lock.unlock() }
        guard result == nil else { return }
        result = error.map { .failure($0) } ?? .success(())
    }

    func read() -> Result<Void, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return result
    }
}

@MainActor
func setMarkdownDefaults(
    application: URL,
    files: [URL],
    contentType: (URL) throws -> UTType?,
    setDefault: (URL, UTType, @escaping @Sendable (Error?) -> Void) -> Void,
    defaultApplication: (URL) -> URL?,
    timeout: TimeInterval = 30
) throws {
    // Resolve every real probe before changing any preference. Never broaden
    // the request to generic text/data or assume a historical alias is valid.
    var types: [UTType] = []
    for file in files {
        guard let type = try contentType(file),
              ["net.daringfireball.markdown", "public.markdown"].contains(type.identifier) else {
            throw HandlerFailure(message: "No supported Markdown content type for \(file.lastPathComponent).")
        }
        if !types.contains(where: { $0.identifier == type.identifier }) { types.append(type) }
    }
    guard !files.isEmpty else { throw HandlerFailure(message: "No Markdown probe files were provided.") }

    let deadline = ProcessInfo.processInfo.systemUptime + timeout
    func waitBriefly() {
        let remaining = max(0, deadline - ProcessInfo.processInfo.systemUptime)
        _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: min(0.01, remaining)))
    }
    for type in types {
        let reply = HandlerReply()
        setDefault(application, type) { reply.complete($0) }
        while reply.read() == nil && ProcessInfo.processInfo.systemUptime < deadline { waitBriefly() }
        guard let result = reply.read() else {
            throw HandlerFailure(message: "Timed out setting the default application for \(type.identifier).")
        }
        // A failed completion remains a failure, including an OSStatus -50.
        try result.get()
    }

    let expected = application.standardizedFileURL.resolvingSymlinksInPath()
    while true {
        let mismatches = files.filter {
            defaultApplication($0)?.standardizedFileURL.resolvingSymlinksInPath() != expected
        }
        if mismatches.isEmpty { return }
        guard ProcessInfo.processInfo.systemUptime < deadline else {
            throw HandlerFailure(message: "Default application verification failed for \(mismatches.map(\.lastPathComponent).joined(separator: ", ")).")
        }
        waitBriefly()
    }
}

@MainActor
func configureInstalledMarkdownDefaults(arguments: [String]) throws {
    guard arguments.count == 2, (arguments[1] as NSString).isAbsolutePath else {
        throw HandlerFailure(message: "Usage: SetDefaultMarkdownHandler.swift /absolute/Markdown2.app")
    }
    let application = URL(fileURLWithPath: arguments[1]).standardizedFileURL
    guard application.pathExtension == "app",
          let bundle = Bundle(url: application),
          ["dev.codex.md2", "dev.codex.md2.development"].contains(bundle.bundleIdentifier ?? ""),
          let executable = bundle.executableURL,
          FileManager.default.fileExists(atPath: executable.path) else {
        throw HandlerFailure(message: "The installed Markdown2 application is missing or invalid: \(application.path)")
    }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("md2-default-handler-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let files = ["md", "markdown"].map { directory.appendingPathComponent("association-check." + $0) }
    for file in files { try Data("# Markdown2 association probe\n".utf8).write(to: file) }
    try setMarkdownDefaults(application: application, files: files,
        contentType: { try $0.resourceValues(forKeys: [.contentTypeKey]).contentType },
        setDefault: { application, type, completion in
            NSWorkspace.shared.setDefaultApplication(at: application, toOpen: type, completion: completion)
        },
        defaultApplication: { NSWorkspace.shared.urlForApplication(toOpen: $0) })
    print("Verified default Markdown editor: \(application.path)")
}

// Unit tests compile this same helper with injected workspace operations.
// The installed CLI has no environment variable or argument that enables mocks.
#if !MD2_DEFAULT_HANDLER_TESTS
do {
    // A synchronous Swift script starts on the main thread, including when
    // the interpreter defaults to Swift 5 language mode.
    try MainActor.assumeIsolated {
        try configureInstalledMarkdownDefaults(arguments: CommandLine.arguments)
    }
} catch {
    FileHandle.standardError.write(Data("Could not configure the default Markdown editor: \(error)\n".utf8))
    exit(1)
}
#endif
