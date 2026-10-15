# v0.6.0 P1 performance measurements

Baseline: `7d7df83ed35c57bff326c305a2333654eeb8fbd3`. The `after` samples measure the fixes included in v0.6.0.

Measured on 2026-10-15 using Apple M4, 32 GB RAM, macOS 26.7.1 and `swiftc -O`. Each scenario is warmed up and measured three times; the report uses the median. Before and after runs used the same input and ran sequentially.

- `before/` and `after/`: original benchmark output.
- `summary.json`: median values extracted from that output, in milliseconds.
- [Fixes, test results and limitations](../../P1-Fixes-2026-10-15.md).
- [Benchmark script](../../../Scripts/benchmark_p1.sh).

Run `swift test` once to prepare the resource bundle, then run `bash Scripts/benchmark_p1.sh` from an Apple Silicon Mac. To measure an older revision, extract `git archive <revision>` into a temporary directory and pass that directory and an output directory as the script arguments.

These are CPU/style microbenchmarks, not end-to-end typing latency. The fixed edit scenario reports background plan calculation separately from main-thread attribute application. Initial full styling uses more total CPU time; the application moves planning off the main thread and applies large changes in yielding chunks.
