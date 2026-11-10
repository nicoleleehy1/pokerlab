# PokerLab benchmarks

All numbers below were measured with `swift run -c release PokerBench` (output pasted
verbatim). Nothing here is estimated. Re-run the command to reproduce; expect a few percent
run-to-run variation (the single-thread exhaustive enumeration varied between 1.07 and
1.31 billion hands/s across runs).

**Machine:** MacBook Pro, Apple M3 Pro (5 performance + 6 efficiency cores = 11 logical),
macOS 27.0, Xcode 27.1 / Swift 6.4, release build. Parallel runs use one child task per
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
