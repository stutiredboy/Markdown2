import Foundation
import Testing
@testable import MD2App
@testable import MD2Core

/// Reviews durable landmarks in complete documents. The normative suite owns
/// per-example conformance; a full HTML snapshot here would hide small failures
/// inside incidental markup from unrelated features.
struct RealDocumentCorpusTests {
    enum Document: String, CaseIterable {
        case readme = "project-readme"
        case technical = "technical-note"
        case chinese = "chinese-long-form"
        case math = "math-heavy"

        var headings: [String] {
            switch self {
            case .readme:
                ["Waypost", "Install a portable copy", "Configure an endpoint", "Roll out the service"]
            case .technical:
                ["Recovering an interrupted spool rotation", "Recovery procedure",
                 "Checks before releasing the hold", "Results | next steps"]
            case .chinese:
                ["社区修理工作坊手记", "开门以前", "交车时问三件事", "零件领用表", "收摊以后"]
            case .math:
                ["Measuring the length of a noisy trace", "Fit over the measured interval",
                 "Integrate the fitted slope", "Comparison run"]
            }
        }

        var landmarks: [String] {
            switch self {
            case .readme:
                [#"href="https://waypost.example.test/guide/windows_(portable).md">portable Windows guide</a>"#,
                 #"class="language-sh""#, "# Keep a separate spool for dry runs",
                 #"<ol start="10""#, "Verify the health check before processing the backlog.",
                 "Re-enable traffic.", #"href="technical-note.md""#]
            case .technical:
                ["### Sample incident entry", "acknowledged batch: 42", "</table>\n<h2",
                 "The recovered worker processed the remaining 180 records",
                 #"href="project-readme.md""#]
            case .chinese:
                [##"href="#零件领用表">跳到零件领用表</a>"##, "<blockquote",
                 ">刹车线</td>", "下周的第一张登记单"]
            case .math:
                [#"math-inline">f'(t)</span>"#, #"id="eq:trace-length""#,
                 ##"href="#eq:trace-length">1</a>"##, ">Fitted arclength</td>",
                 "Keep the residual plot with the estimate."]
            }
        }
    }

    @Test(arguments: Document.allCases)
    func rendersAndMapsEachCompleteDocument(_ document: Document) throws {
        let url = try #require(Bundle.module.url(forResource: document.rawValue, withExtension: "md",
                                                 subdirectory: "Corpus/real-documents"))
        let source = try String(contentsOf: url, encoding: .utf8)
        let lines = source.components(separatedBy: "\n")
        let rendered = MarkdownRenderer().render(source, assetMode: .appScheme)

        #expect(!rendered.body.contains("markdown-source-fallback"))
        #expect(rendered.outline.map(\.title) == document.headings)
        let styledHeadings = MarkdownStylePlan(source).spans.filter { (1...6).contains($0.kind.rawValue) }
            .map { (source as NSString).substring(with: $0.range) }
        for heading in rendered.outline {
            let authored = "\(String(repeating: "#", count: heading.level)) \(heading.title)"
            let line = try #require(lines.indices.contains(heading.line - 1) ? lines[heading.line - 1] : nil)
            #expect(line == authored)
            #expect(rendered.body.contains("<h\(heading.level) id=\"\(heading.id)\" data-md2-source-line=\"\(heading.line)\">"))
        }
        #expect(styledHeadings == rendered.outline.map { "\(String(repeating: "#", count: $0.level)) \($0.title)" })
        for landmark in document.landmarks {
            #expect(rendered.body.contains(landmark), "Missing rendered landmark: \(landmark)")
        }
    }
}
