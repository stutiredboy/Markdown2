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
                    sandbox: URL = sandboxURL,
                    standardOutput: FileHandle? = nil) -> Result<String, Failure> {
        guard FileManager.default.isExecutableFile(atPath: sandbox.path) else { return .failure(.confinementUnavailable) }
        guard !job.isCanceled else { return .failure(.canceled) }
        let process = Process()
        process.executableURL = sandbox
        process.arguments = ["-p", profile, pandoc.path] + arguments
        process.currentDirectoryURL = directory
        let captureError = Failure.launchFailed("Could not capture converter output.")
        let output: BoundedProcessOutput?
        if let standardOutput {
            process.standardOutput = standardOutput
            output = nil
        } else {
            let stdout = Pipe()
            process.standardOutput = stdout
            guard let capture = BoundedProcessOutput(stdout.fileHandleForReading) else { return .failure(captureError) }
            output = capture
        }
        defer { output?.stop() }
        let stderr = Pipe()
        process.standardError = stderr
        guard let errors = BoundedProcessOutput(stderr.fileHandleForReading) else { return .failure(captureError) }
        defer { errors.stop() }
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        guard job.attach(process) else { return .failure(.canceled) }
        defer { job.detach(process) }
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
        return .success(output?.text ?? "")
    }
}

private final class BoundedProcessOutput: @unchecked Sendable {
    private static let byteLimit = 65_536
    private let queue = DispatchQueue(label: "com.markdown2.converter-output")
    private let source: DispatchSourceRead
    private let descriptor: Int32
    private var buffer = [UInt8](repeating: 0, count: 4_096)
    private var data = Data()

    init?(_ handle: FileHandle) {
        descriptor = handle.fileDescriptor
        guard fcntl(descriptor, F_SETFL, O_NONBLOCK) != -1 else { return nil }
        source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [weak self] in self?.drain() }
        source.setCancelHandler { try? handle.close() }
        source.activate()
    }

    func stop() { source.cancel() }

    var text: String {
        queue.sync {
            // Process termination and pipe readability are independently
            // delivered. Read any bytes the asynchronous observer missed.
            if !source.isCancelled { drain() }
            return String(decoding: data, as: UTF8.self)
        }
    }

    private func drain() {
        // Limit each drain so a child that keeps the pipe open and continues
        // writing cannot hold the result path after the parent process exits.
        for _ in 0..<16 {
            let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
            if count == 0 {
                source.cancel()
                return
            }
            if count < 0 {
                if errno == EINTR { continue }
                return
            }
            data.append(buffer, count: min(count, Self.byteLimit - data.count))
        }
    }
}
