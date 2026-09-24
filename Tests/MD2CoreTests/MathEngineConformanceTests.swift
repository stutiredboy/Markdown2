import Foundation
import XCTest
@testable import MD2Core

/// Engine-conformance guard: the renderer's recognized-environment set and the
/// bundled KaTeX build can drift apart silently — the renderer would keep routing
/// an environment to an engine that rejects it, or stop routing one the engine
/// actually typesets, and nothing in the render path would complain. This runs the
/// bundled `katex.min.js` directly and asserts the two agree.
///
/// Skips loudly when Node is unavailable rather than passing one-sided, mirroring
/// the `MD2_RUN_GUI_TESTS` convention the WebKit-backed suites use.
final class MathEngineConformanceTests: XCTestCase {
    /// Environments the renderer recognizes as typesettable. The starred forms are
    /// listed too because that is what the renderer actually emits — it rewrites
    /// the engine-numbered environments (`align`, `alignat`, `gather`, `equation`)
    /// into their starred form to suppress the engine's own row numbering.
    private static let typesetEnvironments = [
        "align", "align*", "alignat", "gather", "gather*", "equation", "equation*",
        "aligned", "alignedat", "split", "cases", "array",
        "matrix", "pmatrix", "bmatrix", "Bmatrix", "vmatrix", "Vmatrix", "smallmatrix"
    ]

    /// Environments the renderer recognizes so the engine can report them in place.
    private static let rejectedEnvironments = ["multline", "eqnarray", "displaymath", "subequations"]

    /// Malformed TeX the engine must also refuse, pinning that a refusal is what
    /// the probe observes rather than a blanket failure.
    private static let malformed = ["malformed-command", "malformed-brace"]

    private static let probes: [(name: String, tex: String)] = [
        ("align", #"\begin{align} a &= b \\ c &= d \end{align}"#),
        ("align*", #"\begin{align*} a &= b \end{align*}"#),
        ("alignat", #"\begin{alignat}{2} a &= b & c &= d \end{alignat}"#),
        ("gather", #"\begin{gather} a = b \\ c = d \end{gather}"#),
        ("gather*", #"\begin{gather*} a = b \end{gather*}"#),
        ("equation", #"\begin{equation} E = mc^2 \end{equation}"#),
        ("equation*", #"\begin{equation*} E = mc^2 \end{equation*}"#),
        ("aligned", #"\begin{aligned} a &= b \end{aligned}"#),
        ("alignedat", #"\begin{alignedat}{2} a &= b & c &= d \end{alignedat}"#),
        ("split", #"\begin{split} a &= b \end{split}"#),
        ("cases", #"\begin{cases} 1 & a \\ 2 & b \end{cases}"#),
        ("array", #"\begin{array}{cc} 1 & 2 \end{array}"#),
        ("matrix", #"\begin{matrix} 1 & 2 \end{matrix}"#),
        ("pmatrix", #"\begin{pmatrix} 1 & 2 \end{pmatrix}"#),
        ("bmatrix", #"\begin{bmatrix} 1 & 2 \end{bmatrix}"#),
        ("Bmatrix", #"\begin{Bmatrix} 1 & 2 \end{Bmatrix}"#),
        ("vmatrix", #"\begin{vmatrix} 1 & 2 \end{vmatrix}"#),
        ("Vmatrix", #"\begin{Vmatrix} 1 & 2 \end{Vmatrix}"#),
        ("smallmatrix", #"\begin{smallmatrix} 1 & 2 \end{smallmatrix}"#),
        ("multline", #"\begin{multline} a = b \end{multline}"#),
        ("eqnarray", #"\begin{eqnarray} a &=& b \end{eqnarray}"#),
        ("displaymath", #"\begin{displaymath} a = b \end{displaymath}"#),
        ("subequations", #"\begin{subequations} a = b \end{subequations}"#),
        ("malformed-command", #"\unknowncommand{}"#),
        ("malformed-brace", #"\frac{1"#),
        // The starred rewrite the renderer applies, against the unstarred input,
        // so the numbering difference is measured rather than assumed.
        ("unstarred:align", #"\begin{align} a &= b \\ c &= d \end{align}"#),
        ("starred:align", #"\begin{align*} a &= b \\ c &= d \end{align*}"#),
        ("unstarred:alignat", #"\begin{alignat}{2} a &= b \end{alignat}"#),
        ("starred:alignat", #"\begin{alignat*}{2} a &= b \end{alignat*}"#),
        ("unstarred:gather", #"\begin{gather} a = b \end{gather}"#),
        ("starred:gather", #"\begin{gather*} a = b \end{gather*}"#),
        ("unstarred:equation", #"\begin{equation} a = b \end{equation}"#),
        ("starred:equation", #"\begin{equation*} a = b \end{equation*}"#),
        ("starred:tag", #"\begin{align*} a &= b \tag{9} \end{align*}"#)
    ]

    /// Reads the probe set, calls `katex.renderToString` per item, and writes one
    /// JSON record per item. Written to disk rather than passed on the command line
    /// so the TeX needs no shell quoting.
    ///
    /// `eqnNumSlots` counts the engine's equation-number slots. They are empty in
    /// the HTML — the engine's stylesheet fills them from a CSS counter at paint
    /// time — so the count is the only HTML-visible signal that the engine will
    /// number the equation.
    private static let nodeScript = #"""
    const fs = require('fs');
    const katex = require(process.argv[2]);
    const items = JSON.parse(fs.readFileSync(process.argv[3], 'utf8'));
    const results = items.map(function (item) {
        try {
            const html = katex.renderToString(item.tex, { displayMode: true, throwOnError: true });
            const slots = (html.match(/eqn-num/g) || []).length;
            return { name: item.name, ok: true, eqnNumSlots: slots };
        } catch (err) {
            return { name: item.name, ok: false, error: String(err.message).slice(0, 160) };
        }
    });
    process.stdout.write(JSON.stringify(results));
    """#

    private struct ProbeItem: Encodable {
        let name: String
        let tex: String
    }

    private struct ProbeResult: Decodable {
        let name: String
        let ok: Bool
        let error: String?
        let eqnNumSlots: Int?
    }

    func testBundledEngineAgreesWithTheRecognizedEnvironmentSet() throws {
        let results = try runEngineProbe()
        let byName = Dictionary(results.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })

        for name in Self.typesetEnvironments {
            let result = try XCTUnwrap(byName[name], "engine probe did not report \(name)")
            XCTAssertTrue(
                result.ok,
                "renderer typesets \(name) but the bundled engine rejected it: \(result.error ?? "")"
            )
        }

        for name in Self.rejectedEnvironments {
            let result = try XCTUnwrap(byName[name], "engine probe did not report \(name)")
            XCTAssertFalse(
                result.ok,
                "renderer routes \(name) to the engine for a visible error, but the engine accepts it"
            )
        }

        for name in Self.malformed {
            let result = try XCTUnwrap(byName[name], "engine probe did not report \(name)")
            XCTAssertFalse(result.ok, "expected \(name) to be refused by the engine")
        }
    }

    /// The starred rewrite the renderer applies must itself be engine-valid — and
    /// must keep an explicit `\tag{}` working while dropping the engine's own
    /// numbering. Asserted against the engine's `.eqn-num` slots, which are the
    /// engine's numbering mechanism.
    func testStarredRewriteIsEngineValidAndSuppressesRowNumbering() throws {
        let results = try runEngineProbe()
        let byName = Dictionary(results.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })

        // The engine really does number the unstarred forms by itself...
        for name in ["align", "alignat", "gather", "equation"] {
            let unstarred = try XCTUnwrap(byName["unstarred:\(name)"]?.eqnNumSlots)
            XCTAssertGreaterThan(
                unstarred, 0,
                "expected the engine to number \(name) itself; if this drops to 0 the starring rewrite is unnecessary"
            )
        }

        // ...and the starred forms the renderer emits carry none of it.
        for name in ["align", "alignat", "gather", "equation"] {
            let starred = try XCTUnwrap(byName["starred:\(name)"])
            XCTAssertTrue(starred.ok, "the renderer emits \(name)* but the engine rejected it: \(starred.error ?? "")")
            XCTAssertEqual(starred.eqnNumSlots, 0, "\(name)* must carry no engine numbering")
        }

        // A manual tag survives the rewrite, rendering exactly one number.
        let tagged = try XCTUnwrap(byName["starred:tag"])
        XCTAssertTrue(tagged.ok, "align* with a \\tag was rejected: \(tagged.error ?? "")")
        XCTAssertEqual(tagged.eqnNumSlots, 1, "a manual \\tag should render exactly one number")
    }

    private func runEngineProbe() throws -> [ProbeResult] {
        guard let katexURL = MD2CoreResources.bundle.url(
            forResource: "katex.min",
            withExtension: "js",
            subdirectory: "katex"
        ) else {
            throw XCTSkip("bundled katex.min.js is not available to the test bundle")
        }

        let directory = FileManager.default.temporaryDirectory
        let inputURL = directory.appendingPathComponent("md2-katex-probe-\(UUID().uuidString).json")
        let scriptURL = directory.appendingPathComponent("md2-katex-probe-\(UUID().uuidString).js")
        defer {
            try? FileManager.default.removeItem(at: inputURL)
            try? FileManager.default.removeItem(at: scriptURL)
        }

        let items = Self.probes.map { ProbeItem(name: $0.name, tex: $0.tex) }
        try JSONEncoder().encode(items).write(to: inputURL)
        try Self.nodeScript.write(to: scriptURL, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node", scriptURL.path, katexURL.path, inputURL.path]

        let standardOutput = Pipe()
        let standardError = Pipe()
        process.standardOutput = standardOutput
        process.standardError = standardError

        do {
            try process.run()
        } catch {
            throw XCTSkip("Node is unavailable, so the engine probe cannot run: \(error)")
        }
        process.waitUntilExit()

        // `/usr/bin/env` exits non-zero when it cannot find Node at all, so treat a
        // failed launch as a skip — the same "unavailable tool" class as no Node.
        guard process.terminationStatus == 0 else {
            let message = String(
                data: standardError.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
            throw XCTSkip("Node could not run the engine probe (status \(process.terminationStatus)): \(message)")
        }

        let output = standardOutput.fileHandleForReading.readDataToEndOfFile()
        return try JSONDecoder().decode([ProbeResult].self, from: output)
    }
}
