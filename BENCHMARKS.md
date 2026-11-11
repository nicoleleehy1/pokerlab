# PokerLab benchmarks

All numbers below were measured with `swift run -c release PokerBench` (output pasted
verbatim). Nothing here is estimated. Re-run the command to reproduce; expect a few percent
run-to-run variation (the single-thread exhaustive enumeration varied between 1.07 and
1.31 billion hands/s across runs).

**Machine:** MacBook Pro, Apple M3 Pro (5 performance + 6 efficiency cores = 11 logical),
macOS 27.0.1, Xcode 27.1 / Swift 6.4, release build. Parallel runs use one child task per
logical core, so efficiency cores are included.

**Not yet measured:** iPhone numbers. These need a physical device and a signing team (see
README). The engine is the same code on iOS, so `PokerBench`-style measurements can be
repeated there from a test target.

## Phase 1: PokerCore (evaluator and equity)

```
PokerBench | 11 logical cores

Evaluator tables built in 24.95 ms (rank table 73775 entries)
Fast evaluator, random 7-card hands (1 thread):   216.5M/s
Reference evaluator (21 subsets, 1 thread):       53.9K/s  -> fast is 4016x faster
Enumerate all 133,784,560 7-card hands (1 thread): 0.10 s = 1313.4M/s
Enumerate all 7-card hands (11 tasks):           0.022 s = 6188.7M/s

MC AhKh vs QsQd preflop       : 1 thread 42.8M/s, 11 tasks 301.1M/s (7.0x); equity 46.22% ± 0.008
MC AKs,QQ+ vs random range    : 1 thread 42.7M/s, 11 tasks 282.8M/s (6.6x); equity 79.70% ± 0.006
MC 3-way 8c7c/AdKs/QhQs        : 1 thread 30.7M/s, 11 tasks 222.8M/s (7.3x); equity 23.58% ± 0.007

Exact AsAh vs KdKc (1,712,304 boards): 1 thread 19.7 ms, 11 tasks 4.9 ms; equity 81.255%
Exact AhKh vs {QQ+,AKo,JTs} on Qd7h2h (18810 deals): 0.39 ms
Stream to ±0.5%: 0.5 ms, 90112 trials, 1 snapshots
Stream to ±0.1%: 0.9 ms, 180224 trials, 2 snapshots
```

How to read these:

- **Random 7-card hands** builds each hand's key from its 64-bit mask, then does one
  table lookup. This is the honest "evaluate an arbitrary hand" number.
- **Enumerate all 7-card hands** uses incremental keys (each nested loop adds one card's
  key), which is how exact equity enumeration runs. That's why it's faster than the random
  case: no per-hand key construction and cache-friendly access.
- **MC trials/s** counts full trials: deal each player's combo (with card-removal
  rejection), complete the board, evaluate every player and record the result. The
  parallel speedup is about 7x on 11 logical cores because 6 of them are efficiency cores.
- **Monte Carlo ± values** are one standard error, in percentage points.
- **Stream** timings come from the `AsyncStream` API with a stopping rule on standard
  error. The first snapshot already holds one batch per worker (11 × 8,192 trials).

### Optimisation log

| Change | Before | After |
|---|---|---|
| Table build: per-multiset strength without `Set`/`filter` allocations | 1,020 ms | 1,008 ms |
| Table build: union-find "next free slot" in first-fit packing | 1,008 ms | 563 ms |
| Table build: ship generated row offsets (`PokerTables offsets`), verify at load | 563 ms | 25 ms |

### Correctness checks behind these numbers (all in `swift test`)

- Fast evaluator equals the reference evaluator on 1,000,000 random 7-card hands plus
  100,000 each of 5- and 6-card hands.
- All 2,598,960 five-card hands and all 133,784,560 seven-card hands produce the textbook
  category frequencies exactly.
- Exact AsAh vs KdKc and AsAd vs 7h2c match a brute-force enumeration with the reference
  evaluator over every board, bit for bit.
- Monte Carlo agrees with exact enumeration within 4 standard errors on heads-up,
  three-way and range-vs-hand spots.

## Phase 2: PokerSolver (CFR+ push/fold)

`swift run -c release PokerBench solver`:

```
Push/fold CFR+ solver: 40 stack depths (1.0 to 20.5 bb), 2,000 iterations each
CPU scalar, 1 thread:        2328.3 ms  (34.4K iterations/s; wall incl. checkpoints 2329 ms)
CPU SIMD16, 1 thread:        516.8 ms  (154.8K iterations/s) -> 4.5x vs scalar
CPU SIMD16, 11 tasks:       87.5 ms wall (incl. checkpoint) -> 26.6x vs scalar
Metal cfr_push_fold (Apple M3 Pro): 203.2 ms GPU, 205.1 ms wall -> 11.5x vs scalar, 2.5x vs SIMD 1 thread, 0.43x vs SIMD 11 tasks; max diff vs CPU 0.063%, worst exploitability 0.0012 mbb
Metal cfr_push_fold_simd (Apple M3 Pro): 78.7 ms GPU, 79.8 ms wall -> 29.6x vs scalar, 6.6x vs SIMD 1 thread, 1.10x vs SIMD 11 tasks; max diff vs CPU 0.010%, worst exploitability 0.0012 mbb
320 depths x 2000 iterations: CPU SIMD 11 tasks 648 ms wall, Metal simd-group kernel 505 ms GPU / 512 ms wall (both incl. one exploitability checkpoint per depth) -> 1.26x; worst exploitability CPU 0.0020, GPU 0.0020 mbb
Worst CPU exploitability after 2000 iterations: 0.0012 mbb/hand
10 bb exploitability (mbb/hand) at iterations 1: 498.915, 10: 11.353, 100: 0.167, 1000: 0.002
10 bb Nash: shove 58.3% of hands, call 37.4%
```

How to read these:

- Each run solves heads-up push/fold (0.5/1 bb blinds, no ante) for 40 stack depths with
  2,000 CFR+ iterations each. An iteration updates both players: four 169x176
  matrix-vector products plus regret-matching+ updates.
- Solve timings exclude the exploitability checkpoints (exact best response, computed on
  the CPU) except where a line says "incl. checkpoint".
- **Metal `cfr_push_fold` (v1)** runs one thread per hand class with serial 169-term dot
  products, one threadgroup per stack depth.
  **Metal `cfr_push_fold_simd` (v2, default)** gives each depth 1,024 threads; each row's dot
  product is split over a 32-lane SIMD group and reduced with `simd_sum`. v2 is 2.6x faster
  than v1.
- The honest conclusion: at this problem size the GPU kernel is about 30x faster than
  scalar CPU and 6.6x faster than one SIMD16 CPU thread, but only level with (1.1-1.3x)
  SIMD16 across all 11 CPU cores. The GPU's advantage grows with batch size (320 depths:
  1.26x).
- GPU and CPU agree to within 0.01% on every strategy frequency. Both reach about
  0.001 mbb/hand exploitability, which is Nash for practical purposes.
- At 10 bb the solved ranges are 58.3% shove / 37.4% call, in line with published
  heads-up push/fold Nash charts (~58% / ~37%).

### Preflop equity table generation (one-off, offline)

`swift run -c release PokerTables preflop` solves all 93,769 canonical ordered combo
matchups (suit isomorphism) by full enumeration of all 1,712,304 boards each, then averages
them into the 169x169 class table shipped with PokerSolver. On this machine it took
**1 h 57 min wall / 6,103 CPU-seconds** (11 tasks; the machine was also running other work).
It only needs re-running if the evaluator changes. Spot checks against Monte Carlo are in the
test suite; AA vs KK averages to 81.95%.

| Change | Before | After |
|---|---|---|
| CPU: scalar loops -> SIMD16 fused matrix-vector + vectorised regret updates (1 thread) | 2,328 ms | 517 ms |
| CPU: SIMD16, one task per stack depth (11 tasks) | 517 ms | 88 ms |
| Metal: v1 row-per-thread -> v2 SIMD-group rows with `simd_sum` | 203 ms | 79 ms |

## Toy games: CFR on Kuhn poker

`swift run -c release PokerBench toy`:

```
Toy games (Kuhn poker, target |value + 1/18| < 1e-4 and exploitability < 1e-4)
CFR                   : 7390 iterations, 34.75 ms solve time (excluding checks)
CFR+                  : 360 iterations, 1.31 ms solve time (excluding checks)
DCFR (1.5, 0, 2)      : 910 iterations, 3.11 ms solve time (excluding checks)
```

- Tabular CFR with alternating updates over the full Kuhn tree (12 infosets, 24 actions).
  Exploitability is an exact best response, checked every 10 iterations (not timed), so
  iteration counts are rounded up to the next multiple of 10.
- On this tiny game CFR+ needs fewer iterations than DCFR. DCFR's advantage reported by
  Brown & Sandholm shows up on poker trees with large mistakes (see the push/fold and river
  sections), not necessarily on Kuhn.
- The test suite checks all three variants reach the value -1/18 and exploitability below
  1e-3 after 20,000 iterations, and the clairvoyance game matches its closed form
  (value (1 + 2s) / (2 (1 + s)), bluff s/(1+s), call 1/(1+s)) for s = 0.5, 1, 2.

## Discounted CFR vs CFR+ on push/fold

`swift run -c release PokerBench dcfr` (both algorithms run 5,000 iterations on each of 40
stack depths, 1.0 to 20.5 bb; exploitability is measured exactly every 10 iterations):

```
Push/fold iterations to reach exploitability targets (mbb/hand), 40 stack depths, checked every 10 iterations
CFR+                 | < 1.0: median 40, mean 44, worst 50 (40/40) | < 0.1: median 140, mean 138, worst 180 (40/40) | < 0.01: median 450, mean 446, worst 620 (40/40) | wall incl. checks 0.61 s
DCFR(1.5, 0.0, 2.0)  | < 1.0: median 20, mean 20, worst 20 (40/40) | < 0.1: median 40, mean 44, worst 60 (40/40) | < 0.01: median 100, mean 99, worst 140 (40/40) | wall incl. checks 0.63 s
```

| Target (mbb/hand) | CFR+ mean iterations | DCFR mean iterations | Reduction |
|---|---|---|---|
| 1.0 | 44 | 20 | 2.2x |
| 0.1 | 138 | 44 | 3.1x |
| 0.01 | 446 | 99 | 4.5x |

- DCFR uses the paper's recommended (α, β, γ) = (1.5, 0, 2): positive regrets scaled by
  t^1.5/(t^1.5+1), negative regrets halved each iteration, strategy sums discounted by
  (t/(t+1))^2. It is a CPU option (scalar and SIMD backends); the Metal kernels stay CFR+.
- Cost per iteration is the same for both, so the reduction in iterations is also the
  reduction in solve time (the "wall incl. checks" column covers all 5,000 iterations plus
  500 exploitability checks per depth, so it is not a time-to-target figure).
- The reduction is in line with the 2-3x Brown & Sandholm report for CFR+ vs DCFR, and larger
  at tight targets. Push/fold trees contain costly mistakes (folding aces, calling with 72o),
  where CFR+ is known to be slow.

## River solver (full-range, on-device CPU)

`swift run -c release PokerBench river <n>`, one process per spot so the peak footprint
belongs to that spot alone. Pot 10, 100 behind, bets of 33%/75% pot (1 size: 75%;
3 sizes: 33%/75%/150%), raises of 75% of the pot after calling, all-in always available,
at most 3 bets/raises. DCFR(1.5, 0, 2), single thread, exploitability (exact best response)
checked every 10 iterations and not counted in "solve":

```
Full ranges, Ks9h5c4d2s, 2 sizes: hands 1081/1081 (canonical 1081/1081), 24 decision nodes, tables 0.56 MB
   180 iterations, exploitability 0.291% pot, solve 204.7 ms, setup 34.5 ms, wall incl. checks 260.9 ms, process peak footprint 6.8 MB
Full ranges, Qh8c7c3d2s, 2 sizes: hands 1081/1081 (canonical 1081/1081), 24 decision nodes, tables 0.56 MB
   190 iterations, exploitability 0.272% pot, solve 206.3 ms, setup 20.2 ms, wall incl. checks 248.5 ms, process peak footprint 6.8 MB
Full ranges, 2c7c9cJdKd (iso), 2 sizes: hands 1081/1081 (canonical 652/652), 24 decision nodes, tables 0.34 MB
   180 iterations, exploitability 0.296% pot, solve 159.6 ms, setup 19.3 ms, wall incl. checks 195.5 ms, process peak footprint 6.8 MB
Full ranges, Ks9h5c4d2s, 1 size: hands 1081/1081 (canonical 1081/1081), 8 decision nodes, tables 0.17 MB
   140 iterations, exploitability 0.273% pot, solve 45.8 ms, setup 19.3 ms, wall incl. checks 70.1 ms, process peak footprint 6.7 MB
Full ranges, Ks9h5c4d2s, 3 sizes: hands 1081/1081 (canonical 1081/1081), 32 decision nodes, tables 0.76 MB
   190 iterations, exploitability 0.288% pot, solve 279.3 ms, setup 20.5 ms, wall incl. checks 329.7 ms, process peak footprint 6.8 MB
BB vs BTN ranges, Ks9h5c4d2s, 2 sizes: hands 536/335 (canonical 536/335), 24 decision nodes, tables 0.23 MB
   200 iterations, exploitability 0.300% pot, solve 93.9 ms, setup 18.7 ms, wall incl. checks 122.5 ms, process peak footprint 6.7 MB
```

| Spot | Hands (OOP/IP) | Iterations to ≤ 0.3% pot | Solve time | Peak footprint |
|---|---|---|---|---|
| Any two cards, 1 size | 1081 / 1081 | 140 | 45.8 ms | 6.7 MB |
| Any two cards, 2 sizes (two boards) | 1081 / 1081 | 180-190 | 205-206 ms | 6.8 MB |
| Any two cards, 2 sizes, suit-isomorphic board | 652 / 652 canonical | 180 | 159.6 ms | 6.8 MB |
| Any two cards, 3 sizes | 1081 / 1081 | 190 | 279.3 ms | 6.8 MB |
| BB defend vs BTN open, 2 sizes | 536 / 335 | 200 | 93.9 ms | 6.7 MB |

- **Machine:** the MacBook Pro M3 Pro above, release build, one thread. **iPhone numbers
  are not measured yet** (they need a device and a signing team). The research doc's
  estimate for an A17/A18 was 0.1-1 s for 1,000 iterations; this solver needs under 200
  iterations for 0.3% of the pot.
- **Peak footprint** is the whole benchmark process (`ri_lifetime_max_phys_footprint`, the
  figure iOS jetsam limits apply to). The solver's own regret and strategy tables are
  0.17-0.76 MB; the rest is the binary, evaluator tables and runtime.
- **How it's fast:** hand strengths are computed once (the board is fixed), showdowns are an
  O(n) two-pointer sweep with per-card blocker sums for card removal, folds use the same
  blocker sums, and regret matching and the DCFR updates run eight hands at a time on
  SIMD8. On boards where suits are interchangeable (here: hearts and spades), suit
  isomorphism cuts the hand list from 1,081 to 652 and solve time by 22%.
- **Correctness checks (in `swift test`):** the clairvoyance game for s = 0.5, 1, 2 and an
  AKQ-style river match their closed forms (bluff s/(1+s), call 1/(1+s), value
  (1 + 2s)/(2(1 + s)) of the pot); sweep terminal values equal an O(n²) brute force; the
  isomorphic solve matches the full solve; EVs are zero-sum; sets never fold.
- In the simulator's Debug build the BB-vs-BTN solve took about 5.5 s. Debug builds the
  engine without optimisation, so that figure is not a performance number.
