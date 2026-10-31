# Inline scaling benchmark

`Scripts/benchmark_inline.sh` builds a release (`swiftc -O`) probe of the inline renderer and renders the scaling workloads that `InlineRenderingPerformanceTests` asserts on: one-line documents of 500, 1,000 and 2,000 fragments, plus the one-fragment-per-line shapes at 1,000 and 2,000. The workloads live in one file, `Tests/MD2CoreTests/InlineScalingWorkload.swift`, which both the tests and the probe compile, so a benchmark number and a scaling test always measure the same document.

## Run it

```sh
swift build
bash Scripts/benchmark_inline.sh
```

The table goes to standard output and to `.audit/inline-benchmark/inline.md`. Each cell is the fastest and the median of `MD2_BENCH_SAMPLES` renders (default 5). The last columns divide the fastest times, so they show the growth per doubling: about 2× when rendering is linear and about 4× when it is quadratic.

Three scaling tests build their own documents and are not in the probe: terminated bare URLs, email autolinks joined by CJK punctuation, and paren-math spans.

To measure another revision, extract its sources and pass the directory. The workloads still come from the current checkout, so both runs render the same documents. Before the linear resolver, a 2,000-fragment render takes seconds, so one sample is enough:

```sh
mkdir -p /tmp/md2-62ae388
git archive 62ae388 Sources | tar -x -C /tmp/md2-62ae388
MD2_BENCH_SAMPLES=1 bash Scripts/benchmark_inline.sh /tmp/md2-62ae388 /tmp/md2-62ae388-out
```

A row marked † means that revision rendered the workload's output incompletely, so its time is not comparable.

## Reference results

Measured on 2026-10-31 with an Apple M4 (32 GB RAM, macOS 26.7) by the commands above.

### `main` (5 samples)

| Workload | 500 min / median (ms) | 1,000 min / median (ms) | 2,000 min / median (ms) | 500→1,000 | 1,000→2,000 |
| --- | ---: | ---: | ---: | ---: | ---: |
| `urlAutolinks` | 9.59 / 9.72 | 18.27 / 19.10 | 36.82 / 37.29 | 1.91× | 2.02× |
| `markdownLinks` | 13.66 / 13.88 | 27.25 / 27.29 | 55.02 / 55.16 | 2.00× | 2.02× |
| `mailtoAutolinks` | 9.07 / 9.11 | 17.65 / 17.82 | 36.66 / 39.41 | 1.95× | 2.08× |
| `entities` | 2.84 / 2.86 | 5.53 / 5.75 | 11.19 / 11.25 | 1.95× | 2.02× |
| `bareURLs` | 19.66 / 20.02 | 38.97 / 42.10 | 73.80 / 74.55 | 1.98× | 1.89× |
| `bareURLsWithEntities` | 23.63 / 23.91 | 46.81 / 46.99 | 94.93 / 95.39 | 1.98× | 2.03× |
| `referenceLinks` | 28.33 / 28.60 | 56.81 / 57.21 | 115.52 / 115.72 | 2.01× | 2.03× |
| `referenceLinksWithProtectedKeys` | 32.65 / 32.98 | 65.57 / 65.73 | 133.06 / 133.98 | 2.01× | 2.03× |
| `verbatimSpans` | 13.39 / 13.49 | 26.93 / 27.24 | 55.05 / 55.12 | 2.01× | 2.04× |
| `unpairedDollars` | 3.93 / 3.98 | 7.81 / 7.88 | 16.18 / 16.23 | 1.99× | 2.07× |
| `unterminatedParenMath` | 3.26 / 3.32 | 6.59 / 6.62 | 13.24 / 13.33 | 2.03× | 2.01× |

| Workload, one per line | 1,000 min / median (ms) | 2,000 min / median (ms) | 1,000→2,000 |
| --- | ---: | ---: | ---: |
| `urlAutolinks` | 24.44 / 24.66 | 50.11 / 50.34 | 2.05× |
| `bareURLs` | 44.06 / 44.37 | 89.33 / 89.77 | 2.03× |

### Before the linear resolver (`62ae388`, 1 sample)

These are the quadratic curves that `fix-quadratic-inline-rendering` and `scan-inline-delimiter-ownership` removed: about 4× per doubling. `openspec/changes/archive/2026-10-19-fix-quadratic-inline-rendering/measurements.md` recorded the same curves with an ad-hoc probe on 2026-10-18; this script reproduces them. `unpairedDollars` was already linear.

| Workload | 500 min / median (ms) | 1,000 min / median (ms) | 2,000 min / median (ms) | 500→1,000 | 1,000→2,000 |
| --- | ---: | ---: | ---: | ---: | ---: |
| `urlAutolinks` | 256.69 / 256.69 | 992.75 / 992.75 | 3998.49 / 3998.49 | 3.87× | 4.03× |
| `markdownLinks` | 244.31 / 244.31 | 963.07 / 963.07 | 3823.26 / 3823.26 | 3.94× | 3.97× |
| `mailtoAutolinks` | 243.45 / 243.45 | 934.10 / 934.10 | 3761.97 / 3761.97 | 3.84× | 4.03× |
| `entities` | 42.14 / 42.14 | 161.13 / 161.13 | 659.58 / 659.58 | 3.82× | 4.09× |
| `bareURLs` | 294.61 / 294.61 | 1121.64 / 1121.64 | 4500.99 / 4500.99 | 3.81× | 4.01× |
| `bareURLsWithEntities` | 879.79 / 879.79 | 3514.27 / 3514.27 | 14120.52 / 14120.52 | 3.99× | 4.02× |
| `referenceLinks` | 324.65 / 324.65 | 1280.79 / 1280.79 | 4967.08 / 4967.08 | 3.95× | 3.88× |
| `referenceLinksWithProtectedKeys` | 908.00 / 908.00 | 3578.58 / 3578.58 | 14574.08 / 14574.08 | 3.94× | 4.07× |
| `verbatimSpans` | 1108.22 / 1108.22 | 4408.55 / 4408.55 | 17828.88 / 17828.88 | 3.98× | 4.04× |
| `unpairedDollars` | 4.19 / 4.19 | 8.10 / 8.10 | 16.26 / 16.26 | 1.93× | 2.01× |
| `unterminatedParenMath` | 62.31 / 62.31 | 246.99 / 246.99 | 1044.50 / 1044.50 | 3.96× | 4.23× |

| Workload, one per line | 1,000 min / median (ms) | 2,000 min / median (ms) | 1,000→2,000 |
| --- | ---: | ---: | ---: |
| `urlAutolinks` | 1047.45 / 1047.45 | 4149.93 / 4149.93 | 3.96× |
| `bareURLs` | 1156.72 / 1156.72 | 4603.57 / 4603.57 | 3.98× |
