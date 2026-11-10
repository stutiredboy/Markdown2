import Darwin
import Foundation

/// Per-invocation cancellation. Only the wrapped converter process is managed;
/// the fixed OS profile is inherited by its children and never grants network.
final class PandocConversionJob: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var canceled = false

    var isCanceled: Bool { lock.withLock { canceled } }

    func attach(_ process: Process) -> Bool {
        lock.withLock {
            guard !canceled else { return false }
            self.process = process
            return true
        }
    }

    func detach(_ process: Process) {
        lock.withLock { if self.process === process { self.process = nil } }
    }

    func cancel() {
        let process = lock.withLock { canceled = true; return self.process }
        if let process { Self.stop(process) }
    }

    static func stop(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.25) {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }
}

enum OfflinePandocProcess {
    static let profile = "(version 1) (allow default) (deny network*)"
    static let sandboxURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")

    enum Failure: Error, Sendable {
        case confinementUnavailable, launchFailed(String), failed(String), timedOut, canceled
    }

    /// The arguments are Process argv, never shell or generated profile source.
    /// A missing/rejected wrapper fails closed, including --version probes.
    static func run(pandoc: URL, arguments: [String], directory: URL?, timeout: TimeInterval,
                    job: PandocConversionJob = PandocConversionJob(),
                    sandbox: URL = sandboxURL) -> Result<String, Failure> {
        guard FileManager.default.isExecutableFile(atPath: sandbox.path) else { return .failure(.confinementUnavailable) }
        guard !job.isCanceled else { return .failure(.canceled) }
        let process = Process()
        process.executableURL = sandbox
        process.arguments = ["-p", profile, pandoc.path] + arguments
        process.currentDirectoryURL = directory
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        let output = BoundedProcessOutput(), errors = BoundedProcessOutput()
        stdout.fileHandleForReading.readabilityHandler = { output.append($0.availableData) }
        stderr.fileHandleForReading.readabilityHandler = { errors.append($0.availableData) }
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        guard job.attach(process) else { return .failure(.canceled) }
        defer {
            job.detach(process)
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            try? stdout.fileHandleForReading.close()
            try? stderr.fileHandleForReading.close()
        }
        do { try process.run() }
        catch { return .failure(.launchFailed(error.localizedDescription)) }
        // Cancellation may win between attach and launch.
        if job.isCanceled { PandocConversionJob.stop(process) }
        let timedOut = finished.wait(timeout: .now() + max(0, timeout)) == .timedOut
        if timedOut {
            PandocConversionJob.stop(process)
            _ = finished.wait(timeout: .now() + 1)
        }
        if job.isCanceled { return .failure(.canceled) }
        if timedOut { return .failure(.timedOut) }
        guard process.terminationStatus == 0 else { return .failure(.failed(errors.text)) }
        return .success(output.text)
    }
}

private final class BoundedProcessOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ bytes: Data) {
        lock.withLock { data.append(bytes.prefix(max(0, 65_536 - data.count))) }
    }
    var text: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
}
