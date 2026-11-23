#!/bin/bash
# Usage: Scripts/benchmark_p1.sh [source-root] [output-dir]
# Each checkout supplies its own SwiftPM targets and benchmark harness.
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd -P)"
source_root="$(cd "${1:-$repo_root}" && pwd -P)"
output_dir="${2:-$repo_root/.audit/p1-benchmark}"

if [ ! -f "$source_root/Tests/MD2CoreTests/P1BenchmarkTests.swift" ]; then
    echo "The selected source root predates this runner. See Docs/Benchmarks/v0.6.0/README.md for the historical benchmark instructions." >&2
    exit 1
fi

metadata="$(
    set -e
    cd "$source_root"
    printf 'configuration=release\nsource_root=%s\n' "$source_root"
    if [ "$(git rev-parse --show-toplevel 2>/dev/null || true)" = "$source_root" ]; then
        printf 'commit=%s\n' "$(git rev-parse HEAD)"
        source_status="$(git status --short)"
        if [ -n "$source_status" ]; then
            printf 'tree=dirty\n%s\n' "$source_status"
        else
            printf 'tree=clean\n'
        fi
    else
        printf 'commit=unknown\ntree=unknown\n'
    fi
    date -u '+run_utc=%Y-%m-%dT%H:%M:%SZ'
    swift --version
    sw_vers
    printf 'architecture=%s\n' "$(uname -m)"
    sysctl hw.model hw.memsize
    shasum -a 256 README.zh-CN.md Examples/Sample.md
)"

mkdir -p "$output_dir"
output_dir="$(cd "$output_dir" && pwd -P)"
sample_dir="$(mktemp -d "$output_dir/.samples.XXXXXX")"
trap 'rm -r "$sample_dir"' EXIT
printf '%s\n' "$metadata" > "$sample_dir/metadata.txt"

MD2_P1_BENCHMARK_OUTPUT="$sample_dir" swift test \
    --package-path "$source_root" --scratch-path "$output_dir/build" --configuration release \
    --disable-swift-testing --filter 'P1BenchmarkTests/testWorkloads'

# An unmatched test filter can exit successfully. Publish the run only when
# the Swift harness produced every scenario's samples in this invocation.
logs=(normal.log adversarial.log real.log edit.log)
for log in "${logs[@]}"; do
    if [ ! -s "$sample_dir/$log" ]; then
        echo "P1 benchmark did not produce $log" >&2
        exit 1
    fi
done
for file in "${logs[@]}" metadata.txt; do
    mv -f "$sample_dir/$file" "$output_dir/$file"
done
printf 'P1 benchmark samples saved in %s\n' "$output_dir"
