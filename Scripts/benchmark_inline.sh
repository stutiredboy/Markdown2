#!/bin/bash
# Usage: Scripts/benchmark_inline.sh [source-root] [output-dir]
# Builds a `swiftc -O` probe of the inline renderer and renders the scaling
# workloads InlineRenderingPerformanceTests uses. To measure another revision,
# extract it with `git archive <revision> Sources | tar -x -C <dir>` and pass
# that directory; the workloads always come from this checkout, so both runs
# render the same documents. Run `swift build` once first for the resource
# bundle. MD2_BENCH_SAMPLES sets the samples per size (default 5).
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
source_root="${1:-$repo_root}"
output_dir="${2:-$repo_root/.audit/inline-benchmark}"
mkdir -p "$output_dir"
output_dir="$(cd "$output_dir" && pwd)"
bundle="$repo_root/.build/arm64-apple-macosx/debug/MD2_MD2Core.bundle"
[ -d "$bundle" ] || { echo "missing $bundle; run swift build first" >&2; exit 1; }
cat > "$output_dir/BundleAccessor.swift" <<ACCESSOR
import Foundation
extension Bundle {
    static var module: Bundle { Bundle(path: "$bundle")! }
}
ACCESSOR
swiftc -O -target arm64-apple-macosx15.0 -o "$output_dir/inline-probe" \
    "$source_root"/Sources/MD2Core/*.swift "$output_dir/BundleAccessor.swift" \
    "$repo_root/Tests/MD2CoreTests/InlineScalingWorkload.swift" \
    "$repo_root/Scripts/benchmark_inline.swift"
"$output_dir/inline-probe" | tee "$output_dir/inline.md"
