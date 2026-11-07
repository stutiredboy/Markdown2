#!/bin/bash
# Usage: Scripts/benchmark_blocks.sh [source-root] [output-dir]
# Compile the selected revision with -O and use this checkout's workloads.
# Run swift build once for resources. MD2_BENCH_SAMPLES/SIZES/WORKLOADS are optional.
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
source_root="${1:-$repo_root}"
output_dir="${2:-$repo_root/.audit/block-benchmark}"
mkdir -p "$output_dir"
output_dir="$(cd "$output_dir" && pwd)"
bundle="$repo_root/.build/arm64-apple-macosx/debug/MD2_MD2Core.bundle"
if [ ! -d "$bundle" ]; then bundle="$repo_root/.build/out/Products/Debug/MD2_MD2Core.bundle"; fi
[ -d "$bundle" ] || { echo "missing MD2_MD2Core.bundle; run swift build first" >&2; exit 1; }
cat > "$output_dir/BundleAccessor.swift" <<ACCESSOR
import Foundation
extension Bundle { static var module: Bundle { Bundle(path: "$bundle")! } }
ACCESSOR
swiftc -O -target arm64-apple-macosx15.0 -o "$output_dir/block-probe" \
    "$source_root"/Sources/MD2Core/*.swift "$output_dir/BundleAccessor.swift" \
    "$repo_root/Tests/MD2CoreTests/BlockScalingWorkload.swift" \
    "$repo_root/Scripts/benchmark_blocks.swift"
"$output_dir/block-probe" "$output_dir/fingerprints.json" | tee "$output_dir/timings.csv"
