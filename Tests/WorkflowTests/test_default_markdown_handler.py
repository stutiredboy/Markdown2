"""Compile the real installer helper; inject only workspace operations in tests."""

from pathlib import Path
import subprocess
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[2]
HELPER = REPO / "Scripts/SetDefaultMarkdownHandler.swift"

HARNESS = r'''
@MainActor
func exercise(_ mode: String) throws {
    let application = URL(fileURLWithPath: "/tmp/Markdown2 With Spaces.app")
    let files = ["md", "markdown"].map { URL(fileURLWithPath: "/tmp/probe." + $0) }
    let markdown = UTType(importedAs: "net.daringfireball.markdown")
    let alias = UTType("public.markdown") ?? UTType(importedAs: "public.markdown")
    var calls: [(URL, String)] = []
    var reads = 0
    let completed = DispatchSemaphore(value: 0)
    func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw NSError(domain: "TestAssertion", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    do {
        try setMarkdownDefaults(application: application, files: files,
            contentType: { file in
                if mode == "generic" && file.pathExtension == "markdown" { return .plainText }
                if mode == "missing" && file.pathExtension == "markdown" { return nil }
                return mode == "distinct" && file.pathExtension == "markdown" ? alias : markdown
            },
            setDefault: { path, type, reply in
                calls.append((path, type.identifier))
                if mode == "timeout" { return }
                if mode == "rejected" {
                    reply(NSError(domain: "InjectedSetter", code: -50))
                    return
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.01) {
                    completed.signal()
                    reply(nil)
                }
            },
            defaultApplication: { _ in
                reads += 1
                if mode == "mismatch" || (mode == "settling" && reads < 3) {
                    return URL(fileURLWithPath: "/tmp/Different.app")
                }
                return application
            },
            timeout: ["timeout", "mismatch"].contains(mode) ? 0.04 : 1)
        try require(["success", "distinct", "settling"].contains(mode), "unexpected success: " + mode)
        try require(calls.allSatisfy { $0.0 == application }, "installer path was replaced by a bundle-ID lookup")
        // Some systems canonicalize an imported public.markdown alias. Check
        // every distinct type actually supplied by the resolver, exactly once.
        let expectedTypes = Set(mode == "distinct" ? [markdown.identifier, alias.identifier] : [markdown.identifier])
        try require(Set(calls.map { $0.1 }) == expectedTypes && calls.count == expectedTypes.count, "wrong or duplicate content type request")
        try require(completed.wait(timeout: .now()) == .success, "returned before the asynchronous completion")
        try require(reads >= 2, "both actual files must be verified")
    } catch {
        switch mode {
        case "generic", "missing":
            try require(calls.isEmpty, "type validation must precede every mutation")
            try require(error.localizedDescription.contains("supported Markdown content type"), "wrong preflight error")
        case "rejected":
            let native = error as NSError
            try require(native.domain == "InjectedSetter" && native.code == -50, "native error was swallowed or replaced")
            try require(reads == 0 && calls.count == 1, "failure must stop before verification or more mutations")
        case "timeout":
            try require(error.localizedDescription.contains("Timed out setting"), "missing callback must fail with a bounded timeout")
        case "mismatch":
            try require(error.localizedDescription.contains("verification failed"), "successful callback is insufficient without actual-file readback")
        default:
            throw error
        }
    }
}
do {
    try exercise(CommandLine.arguments[1])
    print("PASS " + CommandLine.arguments[1])
} catch {
    FileHandle.standardError.write(Data("FAILED: \(error)\n".utf8))
    exit(1)
}
'''


class DefaultMarkdownHandlerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="md2-default-helper-tests-")
        cls.addClassCleanup(cls.temporary.cleanup)
        cls.root = Path(cls.temporary.name)
        test_source = cls.root / "main.swift"
        test_source.write_text(HELPER.read_text() + "\n" + HARNESS)
        cls.executable = cls.root / "handler-tests"
        result = subprocess.run(
            ["swiftc", "-swift-version", "6", "-D", "MD2_DEFAULT_HANDLER_TESTS", str(test_source), "-o", str(cls.executable)],
            text=True, capture_output=True, timeout=60,
        )
        if result.returncode:
            raise AssertionError(result.stdout + result.stderr)

    def exercise(self, mode):
        result = subprocess.run([str(self.executable), mode], text=True, capture_output=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("PASS " + mode, result.stdout)

    def test_async_success_sets_exact_app_once_and_verifies_both_extensions(self):
        self.exercise("success")

    def test_each_distinct_resolved_markdown_type_is_configured(self):
        self.exercise("distinct")

    def test_generic_text_is_rejected_before_any_default_changes(self):
        self.exercise("generic")

    def test_unresolved_second_file_is_rejected_before_any_default_changes(self):
        self.exercise("missing")

    def test_native_rejection_including_minus_50_is_preserved(self):
        self.exercise("rejected")

    def test_missing_completion_times_out(self):
        self.exercise("timeout")

    def test_wrong_default_after_successful_completion_is_a_failure(self):
        self.exercise("mismatch")

    def test_readback_can_settle_within_the_same_deadline(self):
        self.exercise("settling")

    def test_cli_rejects_missing_application_without_mutating_defaults(self):
        result = subprocess.run(
            ["swift", str(HELPER), str(self.root / "Missing.app")],
            text=True, capture_output=True, timeout=15,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("application is missing or invalid", result.stderr)


if __name__ == "__main__":
    unittest.main()
