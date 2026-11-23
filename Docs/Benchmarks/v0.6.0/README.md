# v0.6.0 P1 performance measurements

The baseline is `7d7df83ed35c57bff326c305a2333654eeb8fbd3`. The `after`
samples measure `v0.6.0` at `93bde83be64bf6369f70ff9b39d600234a4d567a`.

Measured on 2026-10-15 using Apple M4, 32 GB RAM, macOS 26.7.1 and `swiftc -O`. Each scenario is warmed up and measured three times; the report uses the median. Before and after runs used the same input and ran sequentially.

- `before/` and `after/`: original benchmark output.
- `summary.json`: median values extracted from that output, in milliseconds.
- [Fixes, test results and limitations](../../P1-Fixes-2026-10-15.md).
- [Current benchmark runner](../../../Scripts/benchmark_p1.sh).

## Run the benchmark on a current checkout

On macOS 15 or later, with the toolchain described in [Contributing](../../../CONTRIBUTING.md),
run from the checkout root.

```sh
bash Scripts/benchmark_p1.sh
```

The script builds the app, its resource bundles and the measurement harness
through SwiftPM in release mode. It writes three samples per input to
`normal.log`, `adversarial.log`, `real.log`, and `edit.log` under
`.audit/p1-benchmark`. `metadata.txt` records the toolchain, system, Git state
and hashes of the two real-document inputs. A source archive without Git
metadata reports an unknown commit and tree state. The normal test suite
exercises every workload with one sample and smaller generated inputs, with
no timing assertions. The original runner also printed untimed HTML diagnostics.
Raw HTML and link behavior are covered by the renderer's P1 regression tests.

To compare two current revisions, run the script in each checkout with its
own output directory. The script also accepts an explicit source root and
output directory, for example `bash Scripts/benchmark_p1.sh /path/to/checkout /path/to/results`.
Run the measurements sequentially on the same idle machine and compare the
medians. Check that input hashes match before comparing real files. The
current harness measures all workloads in a single process and uses a monotonic
clock. Historical results also reflect the older toolchain and app code.

These measurements time rendering and styling without launching the app or
opening a WebKit window. The edit scenario times the plan and changed-range
calculation that the app performs on a background actor, then separately
times AppKit attribute application on the main actor. The asynchronous
scheduling and user-visible latency are outside the measured regions.

## Replay the original v0.6.0 measurements

Use the runner from the original tag on an Apple Silicon Mac. Build its core
bundle with the native SwiftPM build system to produce the debug path that the
original runner expects. Use the recorded toolchain when comparing to the
archived timings.

```sh
replay_dir=$(mktemp -d)
mkdir "$replay_dir/v0.6.0" "$replay_dir/baseline"
git archive v0.6.0 | tar -xf - -C "$replay_dir/v0.6.0"
git archive 7d7df83ed35c57bff326c305a2333654eeb8fbd3 | tar -xf - -C "$replay_dir/baseline"
(
    cd "$replay_dir/v0.6.0"
    swift build --build-system native --target MD2Core
    bash Scripts/benchmark_p1.sh "$replay_dir/baseline" "$replay_dir/before"
    bash Scripts/benchmark_p1.sh "$replay_dir/v0.6.0" "$replay_dir/after"
)
```
