import Foundation
import XCTest
@testable import MD2App

final class OfflinePandocProcessTests: XCTestCase {
    func testNetworkDenyHasRealPositiveAndChildProcessControls() throws {
        let server = try ExportNetworkTestServer()
        defer { server.stop() }
        let positive = UUID().uuidString, denied = UUID().uuidString, child = UUID().uuidString
        let curl = URL(fileURLWithPath: "/usr/bin/curl")
        let process = Process()
        process.executableURL = curl
        process.arguments = ["--silent", "--max-time", "3", "\(server.baseURL)/\(positive).png"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(server.requests.filter { $0.path.contains(positive) }.count, 1)

        let directResult = OfflinePandocProcess.run(pandoc: curl,
            arguments: ["--silent", "--max-time", "3", "\(server.baseURL)/\(denied).png"], directory: nil, timeout: 5)
        guard case .failure = directResult else { return XCTFail("network-capable positive control escaped confinement") }
        XCTAssertFalse(server.requests.contains { $0.path.contains(denied) })

        // Same wrapper surrounds --version and inherits to a child executable.
        let childResult = OfflinePandocProcess.run(pandoc: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "/usr/bin/curl --silent --max-time 3 '\(server.baseURL)/\(child).png' >/dev/null; printf 'pandoc 2.0\\n'"],
            directory: nil, timeout: 5)
        guard case .success(let output) = childResult else { return XCTFail("wrapped local child control failed: \(childResult)") }
        XCTAssertTrue(output.contains("pandoc 2.0"))
        XCTAssertFalse(server.requests.contains { $0.path.contains(child) })
    }

    func testMissingConfinementNeverLaunchesTheExecutable() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sentinel = directory.appendingPathComponent("must-not-exist")
        let outcome = OfflinePandocProcess.run(pandoc: URL(fileURLWithPath: "/usr/bin/touch"),
            arguments: [sentinel.path], directory: directory, timeout: 2,
            sandbox: directory.appendingPathComponent("missing-sandbox"))
        guard case .failure(.confinementUnavailable) = outcome else { return XCTFail("unexpected result: \(outcome)") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: sentinel.path))
    }

    func testRejectedConfinementNeverFallsBackToExecutable() {
        let result = OfflinePandocProcess.run(pandoc: URL(fileURLWithPath: "/usr/bin/true"),
            arguments: [], directory: nil, timeout: 2, sandbox: URL(fileURLWithPath: "/usr/bin/false"))
        guard case .failure = result else { return XCTFail("rejected wrapper was bypassed") }
    }

    func testCancellationAndTimeoutAreBounded() {
        let job = PandocConversionJob()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { job.cancel() }
        let started = Date()
        let canceled = OfflinePandocProcess.run(pandoc: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["10"], directory: nil, timeout: 15, job: job)
        guard case .failure(.canceled) = canceled else { return XCTFail("unexpected cancellation: \(canceled)") }
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
        let timedOut = OfflinePandocProcess.run(pandoc: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["10"], directory: nil, timeout: 0.1)
        guard case .failure(.timedOut) = timedOut else { return XCTFail("unexpected timeout: \(timedOut)") }
    }
}
