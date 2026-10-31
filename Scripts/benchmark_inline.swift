import Foundation

/// Release-build probe for the inline scaling workloads. It renders the same
/// documents `InlineRenderingPerformanceTests` renders (the shared
/// `InlineScalingWorkload`), at the sizes the archived measurements use, and
/// prints a Markdown table. `Scripts/benchmark_inline.sh` builds it.
@main
struct InlineBenchmark {
    @MainActor private static var incomplete: Set<String> = []

    @MainActor static func main() {
        let samples = max(1, Int(ProcessInfo.processInfo.environment["MD2_BENCH_SAMPLES"] ?? "") ?? 5)
        let renderer = MarkdownRenderer()
        // Warm every path once, so the first row is not measured cold.
        for workload in InlineScalingWorkload.allCases { _ = renderer.render(workload.document(count: 100)) }
        print("machine=\(ProcessInfo.processInfo.operatingSystemVersionString) samples=\(samples)")
        print()
        print("| Workload | 500 min / median (ms) | 1,000 min / median (ms) | 2,000 min / median (ms) | 500→1,000 | 1,000→2,000 |")
        print("| --- | ---: | ---: | ---: | ---: | ---: |")
        for workload in InlineScalingWorkload.allCases {
            let timings = [500, 1_000, 2_000].map { count in
                measure(workload.rawValue, count: count, samples: samples, renderer: renderer) {
                    workload.document(count: count)
                } check: { workload.matches($0, count: count) }
            }
            print(row(workload.rawValue, timings))
        }
        print()
        print("| Workload, one per line | 1,000 min / median (ms) | 2,000 min / median (ms) | 1,000→2,000 |")
        print("| --- | ---: | ---: | ---: |")
        for workload in InlineScalingWorkload.onePerLineCases {
            let key = workload.rawValue + " one per line"
            let timings = [1_000, 2_000].map { count in
                measure(key, count: count, samples: samples, renderer: renderer) {
                    workload.onePerLine(count: count)
                } check: { workload.matches($0, count: count) }
            }
            print(row(workload.rawValue, timings, key: key))
        }
        if !incomplete.isEmpty {
            print()
            print("† This revision rendered the workload's output incompletely; its time is not comparable.")
        }
    }

    @MainActor private static func measure(
        _ name: String,
        count: Int,
        samples: Int,
        renderer: MarkdownRenderer,
        document: () -> String,
        check: (String) -> Bool
    ) -> (min: Double, median: Double) {
        let text = document()
        // An older revision may render a newer workload differently; time it
        // anyway and flag the row instead of stopping the comparison.
        if !check(renderer.render(text).body) { incomplete.insert(name) }
        var times: [Double] = []
        for _ in 0..<samples {
            let start = DispatchTime.now().uptimeNanoseconds
            _ = renderer.render(text)
            times.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
        }
        times.sort()
        return (times[0], times[times.count / 2])
    }

    @MainActor private static func row(
        _ name: String,
        _ timings: [(min: Double, median: Double)],
        key: String? = nil
    ) -> String {
        let cells = timings.map { String(format: "%.2f / %.2f", $0.min, $0.median) }
        let ratios = zip(timings, timings.dropFirst()).map { String(format: "%.2f×", $1.min / $0.min) }
        let mark = incomplete.contains(key ?? name) ? " †" : ""
        return "| `\(name)`\(mark) | " + (cells + ratios).joined(separator: " | ") + " |"
    }
}
