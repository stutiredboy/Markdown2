import Darwin
import Foundation
import MD2Core

/// Runs user-supplied regex in a short-lived copy of this executable. ICU's
/// callbacks bound ordinary backtracking but can miss long optimized scans.
enum RegexFindProcess {
    static let workerArgument = "--markdown2-regex-worker"
    private static let queue = DispatchQueue(label: "com.markdown2.regex-worker", qos: .userInitiated)
    private static let requestByteLimit = 6_100_000
    private static let replyByteLimit = 12_500_000

    static func matches(
        of pattern: String, in source: String, caseSensitive: Bool, scope: NSRange?,
        timeout: Duration = .seconds(2)
    ) async throws -> [NSRange] {
        let reply = try await send(
            .matches(pattern: pattern, source: source, caseSensitive: caseSensitive, scope: scope), timeout: timeout
        )
        guard case .matches(let ranges) = reply else { throw RegexSearch.Failure.searchFailed }
        return ranges
    }

    static func makeEdit(
        pattern: String, template: String, source: String, caseSensitive: Bool, scope: NSRange?,
        target: NSRange?
    ) async throws -> RegexFindWorker.Edit? {
        let reply = try await send(.edit(
            pattern: pattern, template: template, source: source, caseSensitive: caseSensitive, scope: scope, target: target
        ))
        guard case .edit(let edit) = reply else { throw RegexSearch.Failure.searchFailed }
        return edit
    }

    static func validateReplacement(
        _ template: String, for pattern: String, caseSensitive: Bool
    ) async throws {
        let reply = try await send(.validate(template: template, pattern: pattern, caseSensitive: caseSensitive))
        guard case .valid = reply else { throw RegexSearch.Failure.searchFailed }
    }

    // The app's executable dispatches here before initializing SwiftUI/AppKit.
    static func runChild() -> Int32 {
        // Also cap CPU in the child if the app exits before it can reap it.
        var limit = rlimit(rlim_cur: 2, rlim_max: 2)
        guard setrlimit(RLIMIT_CPU, &limit) == 0 else { return EXIT_FAILURE }
        do {
            let request = try decode(Request.self, from: .standardInput, maximumBytes: requestByteLimit)
            let reply: Reply
            do {
                reply = try request.evaluate()
            } catch let failure as RegexSearch.Failure {
                reply = .failure(failure)
            }
            try encode(reply, to: .standardOutput, maximumBytes: replyByteLimit)
            return EXIT_SUCCESS
        } catch {
            return EXIT_FAILURE
        }
    }

    private enum Request: Codable, Sendable {
        case matches(pattern: String, source: String, caseSensitive: Bool, scope: NSRange?)
        case edit(pattern: String, template: String, source: String, caseSensitive: Bool, scope: NSRange?, target: NSRange?)
        case validate(template: String, pattern: String, caseSensitive: Bool)

        func checkSize() throws {
            let pattern: String
            let source: String
            let template: String
            switch self {
            case .matches(let query, let text, _, _):
                (pattern, source, template) = (query, text, "")
            case .edit(let query, let replacement, let text, _, _, _):
                (pattern, source, template) = (query, text, replacement)
            case .validate(let replacement, let query, _):
                (pattern, source, template) = (query, "", replacement)
            }
            guard pattern.utf16.prefix(RegexSearch.maximumPatternUTF16 + 1).count <= RegexSearch.maximumPatternUTF16,
                  source.utf16.prefix(RegexSearch.maximumTextUTF16 + 1).count <= RegexSearch.maximumTextUTF16,
                  template.utf16.prefix(RegexSearch.maximumTemplateUTF16 + 1).count <= RegexSearch.maximumTemplateUTF16
            else { throw RegexSearch.Failure.limitExceeded }
        }

        func evaluate() throws -> Reply {
            switch self {
            case .matches(let pattern, let source, let caseSensitive, let scope):
                let matches = try RegexSearch.matches(of: pattern, in: source, caseSensitive: caseSensitive, scope: scope)
                return .matches(matches.map(\.range))
            case .edit(let pattern, let template, let source, let caseSensitive, let scope, let target):
                return .edit(try RegexFindWorker.makeEdit(
                    pattern: pattern, template: template, source: source, caseSensitive: caseSensitive,
                    scope: scope, target: target
                ))
            case .validate(let template, let pattern, let caseSensitive):
                try RegexSearch.validateReplacement(template, for: pattern, caseSensitive: caseSensitive)
                return .valid
            }
        }
    }

    private enum Reply: Codable, Sendable {
        case matches([NSRange])
        case edit(RegexFindWorker.Edit?)
        case valid
        case failure(RegexSearch.Failure)
    }

    private static func send(_ request: Request, timeout: Duration = .seconds(2)) async throws -> Reply {
        let job = Job()
        let reply = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    continuation.resume(with: Result { try run(request, job: job, timeout: timeout) })
                }
            }
        } onCancel: {
            job.cancel()
        }
        try Task.checkCancellation()
        if case .failure(let failure) = reply { throw failure }
        return reply
    }

    private static func run(_ request: Request, job: Job, timeout: Duration) throws -> Reply {
        try job.checkCancellation()
        try request.checkSize()
        let executable = try executableURL()
        // Anonymous seekable descriptors avoid pipe deadlocks when the child
        // is killed mid-message. The private files are unlinked before use.
        let input = try anonymousFile()
        let output = try anonymousFile()
        defer {
            try? input.close()
            try? output.close()
        }
        try encode(request, to: input, maximumBytes: requestByteLimit)
        try input.seek(toOffset: 0)
        let deadline = ContinuousClock.now + timeout
        try job.launch(executable: executable, input: input.fileDescriptor, output: output.fileDescriptor)
        try job.wait(until: deadline)
        try output.seek(toOffset: 0)
        return try decode(Reply.self, from: output, maximumBytes: replyByteLimit)
    }

    private static func encode<T: Encodable>(_ value: T, to file: FileHandle, maximumBytes: Int) throws {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode(value)
        guard data.count <= maximumBytes else { throw RegexSearch.Failure.limitExceeded }
        try file.write(contentsOf: data)
    }

    private static func decode<T: Decodable>(_ type: T.Type, from file: FileHandle, maximumBytes: Int) throws -> T {
        guard let data = try file.read(upToCount: maximumBytes + 1), data.count <= maximumBytes else {
            throw RegexSearch.Failure.searchFailed
        }
        return try PropertyListDecoder().decode(type, from: data)
    }

    private static func anonymousFile() throws -> FileHandle {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Markdown2-regex.XXXXXX")
        var path = url.path.utf8CString
        return try path.withUnsafeMutableBufferPointer { buffer in
            guard let name = buffer.baseAddress else { throw RegexSearch.Failure.searchFailed }
            let fd = mkostemp(name, O_CLOEXEC)
            guard fd >= 0 else { throw RegexSearch.Failure.searchFailed }
            guard unlink(name) == 0 else {
                close(fd)
                throw RegexSearch.Failure.searchFailed
            }
            return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        }
    }

    private static func executableURL() throws -> URL {
        if let executable = Bundle.main.executableURL, executable.lastPathComponent == "Markdown2" {
            return executable
        }
        // SwiftPM's XCTest runner and test bundle may each be Bundle.main.
        // The app product is built next to the test bundle in either case.
        let inputs = CommandLine.arguments + (Bundle.main.bundleURL.pathExtension == "xctest" ? [Bundle.main.bundleURL.path] : [])
        for argument in inputs {
            var url = URL(fileURLWithPath: argument).resolvingSymlinksInPath()
            while url.path != "/" {
                if url.pathExtension == "xctest" {
                    let executable = url.deletingLastPathComponent().appendingPathComponent("Markdown2")
                    if FileManager.default.isExecutableFile(atPath: executable.path) { return executable }
                    break
                }
                url.deleteLastPathComponent()
            }
        }
        throw RegexSearch.Failure.searchFailed
    }

    private final class Job: @unchecked Sendable {
        private let lock = NSLock()
        private var child: pid_t?
        private var cancelled = false

        func checkCancellation() throws {
            if lock.withLock({ cancelled }) { throw CancellationError() }
        }

        func cancel() {
            lock.withLock {
                cancelled = true
                if let child { kill(child, SIGKILL) }
            }
        }

        func launch(executable: URL, input: Int32, output: Int32) throws {
            var actions: posix_spawn_file_actions_t?
            var attributes: posix_spawnattr_t?
            guard posix_spawn_file_actions_init(&actions) == 0 else { throw RegexSearch.Failure.searchFailed }
            defer { posix_spawn_file_actions_destroy(&actions) }
            guard posix_spawnattr_init(&attributes) == 0 else { throw RegexSearch.Failure.searchFailed }
            defer { posix_spawnattr_destroy(&attributes) }
            guard posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0,
                  posix_spawn_file_actions_adddup2(&actions, input, STDIN_FILENO) == 0,
                  posix_spawn_file_actions_adddup2(&actions, output, STDOUT_FILENO) == 0
            else { throw RegexSearch.Failure.searchFailed }

            var arguments: [UnsafeMutablePointer<CChar>?] = [strdup(executable.path), strdup(workerArgument), nil]
            defer { arguments.forEach { free($0) } }
            guard let executablePath = arguments[0], arguments[1] != nil else { throw RegexSearch.Failure.searchFailed }
            try checkCancellation()
            var pid: pid_t = 0
            let status = arguments.withUnsafeMutableBufferPointer { buffer in
                posix_spawn(&pid, executablePath, &actions, &attributes, buffer.baseAddress!, environ)
            }
            guard status == 0 else {
                try checkCancellation()
                throw RegexSearch.Failure.searchFailed
            }
            lock.withLock {
                child = pid
                if cancelled { kill(pid, SIGKILL) }
            }
        }

        func wait(until deadline: ContinuousClock.Instant) throws {
            var timedOut = false
            while true {
                let finished = try lock.withLock {
                    guard let child else { throw RegexSearch.Failure.searchFailed }
                    var status: Int32 = 0
                    // Reap and clear the PID under the same lock used to kill it.
                    // A cancelled job cannot accidentally signal a reused PID.
                    let pid = waitpid(child, &status, WNOHANG)
                    if pid == -1, errno == EINTR { return false }
                    if !timedOut, ContinuousClock.now >= deadline {
                        timedOut = true
                        if pid == 0 { kill(child, SIGKILL) }
                    }
                    if pid == 0 { return false }
                    self.child = nil
                    if cancelled { throw CancellationError() }
                    if timedOut { throw RegexSearch.Failure.limitExceeded }
                    guard pid == child, status == 0 else { throw RegexSearch.Failure.searchFailed }
                    return true
                }
                if finished { return }
                // This dedicated serial queue does not block the main actor
                // or a Swift concurrency executor while waiting for waitpid.
                usleep(5_000)
            }
        }
    }
}
