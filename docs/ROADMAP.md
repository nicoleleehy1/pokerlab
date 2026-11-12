# PokerLab roadmap

Planned work, in rough priority order. Each item lists the scope, the approach, and what has to
be true for it to count as done ("Done when"). Like everything else in the repo, any performance
claim must be a measured number in BENCHMARKS.md.

Already built (for context): the ten-unit EV-graded course, river / turn / flop solvers (CPU
DCFR, plus a Metal river backend), push/fold Nash on CPU and Metal (CFR+ and DCFR), solved
6-max first-in shove charts, toy-game lab, FSRS + per-concept Elo with a held-out check on real
answers, and on-device explanations with Foundation Models.

## 1. Calibration game

Guess your equity, get scored by Brier score, and see a reliability chart. The research doc ranks
it highly: about an hour of probability training improved forecasters' Brier scores by 6-11%.

- **Scope:** a Practice mode. Each round deals a spot and you set an equity slider. The answer is
  scored by Brier score against exact equity, and the session ends on a reliability diagram
  (predicted vs actual, in 10 bins) plus your Brier score over time.
- **Approach:** reuse `EquityQuiz` spots and `EquityCalculator` for exact equity. Add
  `CalibrationScore` (Brier, reliability bins, resolution/calibration decomposition) to PokerCourse.
  Persist rounds in SwiftData and chart them with Swift Charts.
- **Done when:** unit tests check Brier and the bins against hand-computed examples; Profile shows
  your Brier score trend; a UI test plays a 10-round session.

## 2. ICM push/fold solver

Final-table Nash ranges under ICM. The course asks ICM questions, but there's no ICM solver yet.

- **Scope:** 3-6 players left, arbitrary stacks and payouts. Push/fold Nash for the first player
  in, against the players behind, with payoffs in prize equity instead of chips.
- **Approach:** extend `FirstInShoveSolver`'s structure, scoring terminal outcomes with
  `ICM.equities` (Malmuth-Harville, already in PokerCourse) instead of chip EV. Same DCFR loop
  and NashConv.
- **Done when:** with equal payouts (winner takes all) it reproduces the chip-EV chart; tests check
  the ICM risk premium (tighter calls on the bubble) on a known example; benchmark time per solve;
  Unit 10 gets an "ICM shove or fold" lesson graded against it.

## 3. River lab extras

A hand-by-hand strategy grid and node-locking controls. The engine already supports locking
(`RiverSolver.Overrides`), but only the exploit lessons use it.

- **Scope:** a 13×13 grid for any decision node, coloured by action mix, where tapping a class shows
  per-combo frequencies and EVs. Plus a "Lock" sheet: pick a node, set the villain's action
  frequencies (or "bet only the top X%"), and see the hero's best response and EV change.
- **Approach:** aggregate `frequencies(at:hand:)` and `actionEVs` by `HandClass`; reuse
  `RangeGridView`; pass `override(at:)` into `actionEVs` and re-solve the hero side.
- **Done when:** a UI test opens the grid and applies a lock; the locked EVs equal
  `actionEVs(..., overrides:)` in a unit test.

## 4. Precomputed flop library

Compressed solver output shipped with the app, because live full-range flops need over a
gigabyte (see BENCHMARKS.md).

- **Scope:** a set of strategically distinct flops (suit and rank isomorphism, about 1,755
  canonical flops, or a curated subset), solved offline at one or two bet sizes for standard
  single-raised-pot ranges.
- **Approach:** an offline `PokerTables flops` generator built on `StreetSolver` (flop root
  strategies plus turn summaries), with 8-bit quantised frequencies and per-board compression,
  loaded lazily from the bundle.
- **Done when:** the library size, lookup latency and quantisation error (max frequency
  difference vs the full-precision solve) are measured; the app bundle stays within an agreed
  budget; the Lab can show a flop's root strategy instantly.

## 5. Adaptive tuning (FSRS weights)

FSRS still uses its default weights instead of ones fitted to your answers.

- **Scope:** fit the FSRS weights to the logged reviews (`AnswerLogEntry`), on device, once there
  are enough of them (e.g. 200 reviews).
- **Approach:** minimise the log loss of predicted retrievability against review outcomes with
  gradient descent (or the FSRS optimizer's method), starting from the defaults, with the same
  past-to-future split the Model check card uses.
- **Done when:** tests recover known weights from synthetic reviews; the fitted weights beat the
  defaults on held-out reviews before being adopted (otherwise keep the defaults); the Model
  check card shows both.

## 6. Widget and Live Activity restyle

They still use the old orange/green colours instead of the monochrome zinc look.

- **Scope:** Daily Drill widget (small, medium, Lock Screen) and the drill Live Activity (Lock
  Screen and Dynamic Island).
- **Approach:** move the zinc tokens into `App/Shared` so the widget target can use them; switch
  to line SF Symbols; ink/onInk/muted colours with dark-mode variants.
- **Done when:** widget previews and simulator screenshots match the app; no orange or green
  remains; VoiceOver labels are unchanged.

## 7. Timed mode and 3-bet charts

- **Timed mode:** an optional per-question timer in lessons and review (e.g. 15 s). Answers
  past the limit count as Again for FSRS, and the time is logged. The research doc cites a
  small study where novice players improved most under time pressure. **Done when:** the timer
  respects Reduce Motion and VoiceOver (with an extended-time option), and the timing reaches
  the answer log.
- **3-bet charts:** solved 3-bet/fold and call ranges facing an open, by position. The research
  found no sourced chart, so these would come from our own solver. **Approach:** a preflop game
  of open → 3-bet/call/fold → 4-bet-shove/call/fold at a fixed stack, solved with DCFR, in
  the same structure as `FirstInShoveSolver`. **Done when:** solver tests (NashConv, symmetry
  checks) pass and a Unit 3 lesson grades 3-bet decisions by EV against the solved ranges.

## Needs Nicole (outside the code)

- Apple Developer team ID, bundle ID prefix, App Group and CloudKit container.
- iPhone benchmark runs (river, turn, push/fold, Foundation Models latency) on a physical device.
- Training photos and a `CardDetector.mlmodel`; device tests of the camera, Siri and the Live
  Activity.
