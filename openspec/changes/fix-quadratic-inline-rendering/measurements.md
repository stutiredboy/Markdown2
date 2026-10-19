# Measurements — fix-quadratic-inline-rendering

Environment: Apple M4, 32 GB RAM, macOS 26.7.1 (25G241), `swiftc -O` release probe.
Checkout: `62ae388` (`origin/main`), renderer `Sources/MD2Core/MarkdownRenderer.swift` 3,133 lines.
Probe: all fragments on one line unless marked "one per line"; warm-up is implicit per process;
500/1,000 use two samples, 2,000 uses one sample. `min` is the primary comparison value.

## Pre-fix baseline `[measured: 2026-10-18]`

### Single-line fragments

| Workload | 500 min / median (ms) | 1,000 min / median (ms) | 2,000 (ms) | 500→1,000 | 1,000→2,000 |
| --- | ---: | ---: | ---: | ---: | ---: |
| `<https://…>` autolinks | 310.75 / 331.68 | 1,200.05 / 1,219.00 | 4,947.60 | 3.86× | 4.12× |
| `[link](https://…)` | 289.23 / 296.58 | 1,152.30 / 1,168.98 | 4,662.28 | 3.98× | 4.05× |
| `<mailto:…>` autolinks | 295.24 / 299.07 | 1,157.41 / 1,168.04 | 4,630.07 | 3.92× | 4.00× |
| `&nbsp;` entities | 50.71 / 50.84 | 197.79 / 198.34 | 806.90 | 3.90× | 4.08× |
| bare `https://…` URLs | 357.88 / 367.41 | 1,379.25 / 1,389.23 | 5,531.84 | 3.85× | 4.01× |
| bare URLs with `&amp;` | 1,091.81 / 1,095.48 | 4,377.21 / 4,380.21 | 17,705.97 | 4.01× | 4.04× |
| reference links | 388.36 / 391.35 | 1,484.68 / 1,517.25 | 6,041.04 | 3.82× | 4.07× |
| reference links, protected keys | 1,086.06 / 1,090.79 | 4,311.91 / 4,340.57 | 17,709.01 | 3.97× | 4.11× |

### One fragment per line (report's reference-list shape)

| Workload | 1,000 (ms) | 2,000 (ms) | Ratio |
| --- | ---: | ---: | ---: |
| `<https://…>` autolinks | 1,317.43 | 5,269.00 | 4.00× |
| bare `https://…` URLs | 1,492.91 | 5,841.59 | 3.91× |

All workloads show the quadratic curve before the fix: doubling the fragment count costs about 4×.
The entity-bearing bare-URL and protected-key reference-link cases are roughly 3× the plain cases
because `source(in:)` adds another per-fragment scan on every match.

## Post-fix `[measured: 2026-10-18]`

Same machine, probe, and sizes as the baseline. The 500/1,000 samples are the minimum of two
runs; the 2,000 sample is one run. Ratios are computed from the 500/1,000/2,000 minima.

### Single-line fragments

| Workload | 500 (ms) | 1,000 (ms) | 2,000 (ms) | 500→1,000 | 1,000→2,000 | 2,000 before → after |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `<https://…>` autolinks | 15.78 | 26.55 | 57.69 | 1.68× | 2.17× | 4,947.60 → 57.69 (85.8× faster) |
| `[link](https://…)` | 18.13 | 36.41 | 74.42 | 2.01× | 2.04× | 4,662.28 → 74.42 (62.6×) |
| `<mailto:…>` autolinks | 12.98 | 26.38 | 53.03 | 2.03× | 2.01× | 4,630.07 → 53.03 (87.3×) |
| `&nbsp;` entities | 3.52 | 7.16 | 14.09 | 2.03× | 1.97× | 806.90 → 14.09 (57.3×) |
| bare `https://…` URLs | 25.02 | 50.56 | 100.89 | 2.02× | 2.00× | 5,531.84 → 100.89 (54.8×) |
| bare URLs with `&amp;` | 34.24 | 70.86 | 136.62 | 2.07× | 1.93× | 17,705.97 → 136.62 (129.6×) |
| reference links | 39.30 | 76.31 | 152.03 | 1.94× | 1.99× | 6,041.04 → 152.03 (39.7×) |
| reference links, protected keys | 44.01 | 84.96 | 177.66 | 1.93× | 2.09× | 17,709.01 → 177.66 (99.7×) |

### One fragment per line (report's reference-list shape)

| Workload | 1,000 (ms) | 2,000 (ms) | Ratio | 2,000 before → after |
| --- | ---: | ---: | ---: | ---: |
| `<https://…>` autolinks | 41.98 | 78.51 | 1.87× | 5,269.00 → 78.51 (67.1×) |
| bare `https://…` URLs | 61.54 | 122.58 | 1.99× | 5,841.59 → 122.58 (47.7×) |

Every workload now grows approximately linearly (1.7×–2.2× per doubling instead of ~4×).
The entity-bearing bare-URL and protected-key reference-link workloads improved the most
because they previously paid both the `restore` and `source` per-fragment scans.

Debug-suite timing (`swift test --filter InlineRenderingPerformanceTests`): the pre-fix suite
failed after 51.8 s; the post-fix suite passes in 4.6 s, including all characterization and
autolink-edge tests.

## Result

- All 21 change tasks complete; every workload grows linearly (1.7×–2.2× per doubling).
- The 2,000-fragment single-line renders dropped from 0.8–17.7 s to 14–178 ms; the one-per-line
  report shape dropped from 5.3–5.8 s to 79–123 ms.
- Verification: `swift test` passes 637 tests in 78 suites (non-GUI); the new suite has 22 tests;
  `swift build -c release` succeeds; `openspec validate --strict` passes.
- Files: `Sources/MD2Core/MarkdownRenderer.swift` (shared resolver, buffered `replaceMatches`,
  `LinkDestinationIndex`, comments) and `Tests/MD2CoreTests/InlineRenderingPerformanceTests.swift`.
- Rollback: revert the shared resolver (`InlineProtector`), the `replaceMatches` builder, and the
  D3 destination index; the pre-fix behavior is documented by the red-state test run.


