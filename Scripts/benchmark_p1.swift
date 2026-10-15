import AppKit
import Foundation

@main
struct AuditProbe {
    @MainActor static func main() throws {
        let renderer = MarkdownRenderer()
        _ = renderer.render("warm up")
        print("machine=\(ProcessInfo.processInfo.operatingSystemVersionString)")
        if CommandLine.arguments.contains("--real") {
            for path in ["README.zh-CN.md", "Examples/Sample.md"] {
                let content = try String(contentsOfFile: path, encoding: .utf8)
                let tv = NSTextView()
                tv.string = content
                var timings: [[Double]] = []
                for _ in 0..<3 {
                    var start = CFAbsoluteTimeGetCurrent()
                    _ = renderer.render(content)
                    let renderMS = (CFAbsoluteTimeGetCurrent() - start) * 1000
                    start = CFAbsoluteTimeGetCurrent()
                    MarkdownTextStyler.apply(to: tv)
                    timings.append([renderMS, (CFAbsoluteTimeGetCurrent() - start) * 1000])
                }
                print("file=\(path) bytes=\(content.utf8.count) render_style_ms=\(timings)")
            }
            return
        }
        if CommandLine.arguments.contains("--edit") {
            for size in [10_000, 100_000, 500_000, 1_000_000] {
                let chunk = "## 标题 Example\n\n这是客户端性能审查的测试段落。English words **bold** and `code`.\n\n- item one\n- item two\n\n"
                let content = String(repeating: chunk, count: max(1, size / chunk.utf8.count))
                let view = NSTextView()
                view.string = content
                MarkdownTextStyler.apply(to: view)
                #if P1_FIXED
                var previous = MarkdownStylePlan(content)
                #endif
                var planMS: [Double] = []
                var applyMS: [Double] = []
                var changedLengths: [Int] = []
                for _ in 0..<3 {
                    let position = (view.string as NSString).length / 2
                    view.textStorage!.replaceCharacters(in: NSRange(location: position, length: 0), with: "x")
                    var start = CFAbsoluteTimeGetCurrent()
                    #if P1_FIXED
                    let plan = MarkdownStylePlan(view.string)
                    let range = plan.changedRange(from: previous)
                    planMS.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
                    start = CFAbsoluteTimeGetCurrent()
                    MarkdownTextStyler.apply(plan, range: range, to: view)
                    changedLengths.append(range.length)
                    previous = plan
                    #else
                    MarkdownTextStyler.apply(to: view)
                    changedLengths.append((view.string as NSString).length)
                    #endif
                    applyMS.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
                }
                print("bytes=\(content.utf8.count) background_plan_ms=\(planMS) main_style_ms=\(applyMS) changed_utf16=\(changedLengths)")
            }
            return
        }
        let sizes = CommandLine.arguments.contains("--adversarial") ? [1000, 5000, 10000, 20000] : [10000, 100000, 500000, 1000000]
        let chunk = "## 标题 Example\n\n这是客户端性能审查的测试段落。English words **bold** and `code`.\n\n- item one\n- item two\n\n"
        for size in sizes {
            let content = CommandLine.arguments.contains("--adversarial")
                ? String(repeating: "[", count: size)
                : String(repeating: chunk, count: max(1, size / chunk.utf8.count))
            var renderTimes: [Double] = []
            var styleTimes: [Double] = []
            let tv = NSTextView()
            tv.string = content
            var htmlBytes = 0
            for _ in 0..<3 {
                var start = CFAbsoluteTimeGetCurrent()
                let result = renderer.render(content)
                renderTimes.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
                htmlBytes = result.html.utf8.count
                start = CFAbsoluteTimeGetCurrent()
                MarkdownTextStyler.apply(to: tv)
                styleTimes.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
            }
            print("bytes=\(content.utf8.count) lines=\(content.split(separator: "\n", omittingEmptySubsequences: false).count) render_ms=\(renderTimes) style_ms=\(styleTimes) html_bytes=\(htmlBytes)")
            fflush(stdout)
        }
        let raw = "<img src=\"missing-audit.png\" onerror=\"document.body.dataset.audit='EXECUTED'\">"
        print("raw_html_probe=\(renderer.render(raw).body)")
        print("entity_link_probe=\(renderer.render("[x](javascript&#58;void%200)").body)")
        let empty = renderer.render("")
        print("empty_html_bytes=\(empty.html.utf8.count)")
    }
}
