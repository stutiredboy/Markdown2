import Foundation
import CryptoKit

/// Same workloads for every source revision; semantic fingerprints include the
/// whole page, source metadata, outline, statistics and front-matter macros.
@main
struct BlockBenchmark {
    static func main() throws {
        let environment = ProcessInfo.processInfo.environment
        let samples = max(1, Int(environment["MD2_BENCH_SAMPLES"] ?? "") ?? 5)
        let sizes = (environment["MD2_BENCH_SIZES"] ?? "250,500,1000").split(separator: ",").compactMap { Int($0) }
        let selected = environment["MD2_BENCH_WORKLOADS"].map { Set($0.split(separator: ",").map(String.init)) }
        let renderer = MarkdownRenderer()
        var fingerprints: [String: String] = [:]
        print("machine=\(ProcessInfo.processInfo.operatingSystemVersionString) samples=\(samples) build=swiftc-O")
        print("workload,count,source_bytes,min_ms,median_ms,complete")
        for workload in BlockScalingWorkload.allCases where selected?.contains(workload.rawValue) ?? true {
            _ = renderer.render(workload.document(count: 16), assetMode: .appScheme)
            var timings = Array(repeating: [Double](), count: sizes.count)
            let texts = sizes.map { workload.document(count: $0) }
            // Alternate sizes so a scheduler/thermal stretch affects all sizes.
            for _ in 0..<samples {
                for index in sizes.indices {
                    let start = ContinuousClock.now
                    _ = renderer.render(texts[index], assetMode: .appScheme)
                    let elapsed = start.duration(to: .now).components
                    timings[index].append(Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15)
                }
            }
            for index in sizes.indices {
                let count = sizes[index]
                let rendered = renderer.render(texts[index], assetMode: .appScheme)
                let complete = workload.matches(rendered.body, headingCount: rendered.outline.count, count: count)
                let sorted = timings[index].sorted()
                print("\(workload.rawValue),\(count),\(texts[index].utf8.count),\(String(format: "%.3f", sorted[0])),\(String(format: "%.3f", sorted[sorted.count / 2])),\(complete)")
                fflush(stdout)
                let payload: [String: Any] = [
                    "html": rendered.html, "body": rendered.body,
                    "outline": rendered.outline.map { ["id": $0.id, "title": $0.title, "line": $0.line, "level": $0.level] as [String: Any] },
                    "stats": [rendered.stats.words, rendered.stats.characters, rendered.stats.lines, rendered.stats.readingMinutes],
                    "macros": rendered.mathMacros
                ]
                let bytes = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
                fingerprints["\(workload.rawValue)-\(count)"] = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
                guard complete else { throw NSError(domain: "IncompleteBenchmark", code: 1) }
            }
        }
        let data = try JSONSerialization.data(withJSONObject: fingerprints, options: [.sortedKeys, .prettyPrinted])
        try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
    }
}
