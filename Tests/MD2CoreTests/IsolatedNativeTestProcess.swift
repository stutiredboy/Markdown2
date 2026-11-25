import Darwin
import XCTest

extension XCTestCase {
    /// A completed native app lifecycle leaves later RunLoop-only fixtures
    /// sharing automatic undo groups. Keep that lifecycle in a private process.
    /// Each child executes the original case with its original 20s event limit.
    @MainActor func runInIsolatedNativeProcess(_ method: String, childVariable: String) throws -> Bool {
        let className = NSStringFromClass(type(of: self))
        if let selected = ProcessInfo.processInfo.environment[childVariable] {
            guard selected == method else {
                throw NSError(domain: className, code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Unexpected native child case: \(selected), got \(method)"])
            }
            return false
        }

        let selector = String(method.dropLast(2))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["xctest", "-XCTest", "\(className)/\(selector)",
                             Bundle(for: type(of: self)).bundlePath]
        var environment = ProcessInfo.processInfo.environment
        environment[childVariable] = method
        process.environment = environment
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("md2-native-\(UUID()).log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let output = try FileHandle(forWritingTo: log)
        defer { try? output.close() }
        process.standardOutput = output
        process.standardError = output
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        // A case can run several original 20s event probes. This outer limit
        // bounds process cleanup without relaxing any individual event probe.
        let completed = finished.wait(timeout: .now() + 120) == .success
        var terminated = completed
        if !terminated {
            process.terminate()
            terminated = finished.wait(timeout: .now() + 3) == .success
            if !terminated {
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
                terminated = finished.wait(timeout: .now() + 3) == .success
            }
        }
        let diagnostics = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        print("Native child \(method):\n\(diagnostics)")
        XCTAssertTrue(completed, "Native child exceeded 120s; log: \(log.path)")
        XCTAssertTrue(terminated, "Native child did not terminate; pid: \(process.processIdentifier), log: \(log.path)")
        guard terminated else { return true }
        let marker = "MD2_NATIVE_COMPLETED=\(method)"
        let markerCount = diagnostics.split(whereSeparator: \.isNewline).filter { $0 == marker }.count
        let passed = diagnostics.contains("Test Case '-[\(className) \(selector)]' passed (")
        XCTAssertEqual(process.terminationReason, .exit, "Native child crashed; log: \(log.path)")
        XCTAssertEqual(process.terminationStatus, 0, "Native child failed; log: \(log.path)")
        XCTAssertEqual(markerCount, 1, "Native child did not complete exactly once; log: \(log.path)")
        XCTAssertTrue(passed, "Expected native case did not pass (missing, skipped, or failed); log: \(log.path)")
        if completed, process.terminationReason == .exit, process.terminationStatus == 0, markerCount == 1, passed {
            try? FileManager.default.removeItem(at: log)
        }
        return true
    }
}
