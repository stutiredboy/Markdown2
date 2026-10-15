#!/bin/bash
# Usage: Scripts/benchmark_p1.sh [source-root] [output-dir]
# To compare a revision, extract it with git archive and pass that directory.
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
source_root="${1:-$repo_root}"
output_dir="${2:-$repo_root/.audit/p1-benchmark}"
mkdir -p "$output_dir"
output_dir="$(cd "$output_dir" && pwd)"
# Compile the same sources into one optimized probe module, avoiding app launch.
sed '/^import MD2Core$/d' "$source_root/Sources/MD2App/MarkdownTextStyler.swift" > "$output_dir/MarkdownTextStyler.swift"
cat > "$output_dir/BundleAccessor.swift" <<ACCESSOR
import Foundation
extension Bundle {
    static var module: Bundle { Bundle(path: "$repo_root/.build/arm64-apple-macosx/debug/MD2_MD2Core.bundle")! }
}
ACCESSOR
flags=(-D P1_BASELINE)
if [ -f "$source_root/Sources/MD2App/DocumentRenderWorker.swift" ]; then flags+=(-D P1_FIXED); fi
swiftc -O -target arm64-apple-macosx15.0 "${flags[@]}" -o "$output_dir/probe" \
    "$source_root"/Sources/MD2Core/*.swift "$output_dir/BundleAccessor.swift" \
    "$output_dir/MarkdownTextStyler.swift" "$source_root/Sources/MD2App/CodeBlockLayoutManager.swift" \
    "$repo_root/Scripts/benchmark_p1.swift"
cd "$source_root"
"$output_dir/probe" > "$output_dir/normal.log"
"$output_dir/probe" --adversarial > "$output_dir/adversarial.log"
"$output_dir/probe" --real > "$output_dir/real.log"
"$output_dir/probe" --edit > "$output_dir/edit.log"
