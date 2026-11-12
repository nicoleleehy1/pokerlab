import PokerCore
import PokerSolver
import Darwin

// PokerBench: prints throughput numbers for BENCHMARKS.md. Run with:
//   swift run -c release PokerBench [core|solver|all]   (default: all)
let clock = ContinuousClock()

func seconds(_ d: Duration) -> Double {
    Double(d.components.seconds) + Double(d.components.attoseconds) * 1e-18
}

func fmt(_ x: Double, _ digits: Int = 1) -> String {
    var s = String(Int((x * pow10(digits)).rounded()))
    guard digits > 0 else { return s }
    while s.count <= digits { s = "0" + s }
    s.insert(".", at: s.index(s.endIndex, offsetBy: -digits))
    return s
}
func pow10(_ n: Int) -> Double { (0..<n).reduce(1.0) { a, _ in a * 10 } }
func millions(_ perSecond: Double) -> String { fmt(perSecond / 1e6, 1) + "M/s" }

@inline(never) func sink<T>(_ x: T) { withExtendedLifetime(x) {} }

let cores = EquityCalculator.defaultParallelism
print("PokerBench | \(cores) logical cores")
print("")

let mode = CommandLine.arguments.dropFirst().first ?? "all"
var checksum: UInt64 = 0
if mode == "core" || mode == "all" { try await runCore() }
if mode == "solver" || mode == "all" { try await runSolver() }
if mode == "toy" || mode == "all" { runToy() }
if mode == "dcfr" || mode == "all" { await runDCFR() }
if mode == "firstin" || mode == "all" { runFirstIn() }
if mode == "rivergpu" { runRiverGPU() }
if mode == "street" { runStreet(only: CommandLine.arguments.dropFirst(2).first.flatMap(Int.init)) }
if mode == "river" || mode == "all" { runRiver(only: CommandLine.arguments.dropFirst(2).first.flatMap(Int.init)) }
print("")
print("checksum \(checksum)")

nonisolated func enumerateAll(firsts: some Sequence<Int>) -> UInt64 {
    let eval = HandEvaluator.shared
    var local: UInt64 = 0
    for a in firsts {
        let ka = eval.adding(Card(rawValue: UInt8(a)), to: .empty)
        for b in (a+1)..<52 { let kb = eval.adding(Card(rawValue: UInt8(b)), to: ka)
        for c in (b+1)..<52 { let kc = eval.adding(Card(rawValue: UInt8(c)), to: kb)
        for d in (c+1)..<52 { let kd = eval.adding(Card(rawValue: UInt8(d)), to: kc)
        for e in (d+1)..<52 { let ke = eval.adding(Card(rawValue: UInt8(e)), to: kd)
        for f in (e+1)..<52 { let kf = eval.adding(Card(rawValue: UInt8(f)), to: ke)
        for g in (f+1)..<52 {
            local &+= UInt64(eval.evaluate(eval.adding(Card(rawValue: UInt8(g)), to: kf)).rawValue)
        } } } } } }
    }
    return local
}

@MainActor func runCore() async throws {
// 1. Table construction (first use).
var t0 = clock.now
let tables = EvaluatorTables.shared
print("Evaluator tables built in \(fmt(seconds(clock.now - t0) * 1000, 2)) ms (rank table \(tables.rankTableSize) entries)")
let eval = HandEvaluator.shared

// 2. Random 7-card hands from a precomputed array (includes key construction from the mask).
var rng = Xoshiro256(seed: 1)
let handCount = 1 << 20
var hands: [CardSet] = []
hands.reserveCapacity(handCount)
for _ in 0..<handCount {
    var s = CardSet()
    while s.count < 7 { s.insert(Card(rawValue: UInt8(rng.next(below: 52)))) }
    hands.append(s)
}
let rounds = 20
t0 = clock.now
for _ in 0..<rounds { for h in hands { checksum &+= UInt64(eval.evaluate(h).rawValue) } }
let randomRate = Double(handCount * rounds) / seconds(clock.now - t0)
print("Fast evaluator, random 7-card hands (1 thread):   \(millions(randomRate))")

// 3. Reference evaluator on the same hands.
let refCount = 50_000
t0 = clock.now
for h in hands.prefix(refCount) { checksum &+= UInt64(ReferenceEvaluator.evaluate(Array(h)).rawValue) }
let refRate = Double(refCount) / seconds(clock.now - t0)
print("Reference evaluator (21 subsets, 1 thread):       \(fmt(refRate / 1e3, 1))K/s  -> fast is \(fmt(randomRate / refRate, 0))x faster")

// 4. Exhaustive enumeration of all 133,784,560 7-card hands with incremental keys.
t0 = clock.now
checksum &+= enumerateAll(firsts: 0..<46)
let enumSingle = seconds(clock.now - t0)
print("Enumerate all 133,784,560 7-card hands (1 thread): \(fmt(enumSingle, 2)) s = \(millions(133_784_560 / enumSingle))")

t0 = clock.now
let parallelSum = await withTaskGroup(of: UInt64.self) { group in
    for w in 0..<cores { group.addTask { enumerateAll(firsts: stride(from: w, to: 46, by: cores)) } }
    var total: UInt64 = 0
    for await part in group { total &+= part }
    return total
}
checksum &+= parallelSum
let enumParallel = seconds(clock.now - t0)
print("Enumerate all 7-card hands (\(cores) tasks):           \(fmt(enumParallel, 3)) s = \(millions(133_784_560 / enumParallel))")
print("")

// 5. Monte Carlo trials/sec.
func mc(_ name: String, _ req: EquityRequest, trials: Int) async throws {
    let single = try await EquityCalculator.monteCarlo(req, trials: trials / 4, seed: 7, parallelism: 1)
    let multi = try await EquityCalculator.monteCarlo(req, trials: trials, seed: 7, parallelism: cores)
    let r1 = Double(single.samples) / seconds(single.elapsed)
    let rN = Double(multi.samples) / seconds(multi.elapsed)
    print("MC \(name): 1 thread \(millions(r1)), \(cores) tasks \(millions(rN)) (\(fmt(rN / r1, 1))x); equity \(fmt(multi.equities[0] * 100, 2))% ± \(fmt(multi.standardErrors[0] * 100, 3))")
}
try await mc("AhKh vs QsQd preflop       ", EquityRequest(hands: [HoleCards("AhKh")!, HoleCards("QsQd")!]), trials: 40_000_000)
try await mc("AKs,QQ+ vs random range    ", EquityRequest(players: [try HandRange("AKs, QQ+"), .all]), trials: 40_000_000)
try await mc("3-way 8c7c/AdKs/QhQs        ", EquityRequest(hands: [HoleCards("8c7c")!, HoleCards("AdKs")!, HoleCards("QhQs")!]), trials: 40_000_000)

// 6. Exact enumeration.
let aaKK = EquityRequest(hands: [HoleCards("AsAh")!, HoleCards("KdKc")!])
let ex1 = try await EquityCalculator.exact(aaKK, parallelism: 1)
let exN = try await EquityCalculator.exact(aaKK, parallelism: cores)
print("")
print("Exact AsAh vs KdKc (1,712,304 boards): 1 thread \(fmt(seconds(ex1.elapsed) * 1000, 1)) ms, \(cores) tasks \(fmt(seconds(exN.elapsed) * 1000, 1)) ms; equity \(fmt(exN.equities[0] * 100, 3))%")
let flopReq = EquityRequest(players: [HandRange(HoleCards("AhKh")!), try HandRange("QQ+, AKo, JTs")], board: CardSet(parsing: "Qd7h2h")!)
let exF = try await EquityCalculator.exact(flopReq)
print("Exact AhKh vs {QQ+,AKo,JTs} on Qd7h2h (\(exF.samples) deals): \(fmt(seconds(exF.elapsed) * 1000, 2)) ms")

// 7. Live stream: time to reach a target standard error.
for target in [0.005, 0.001] {
    var opts = EquityCalculator.StreamOptions()
    opts.exactThreshold = 0
    opts.targetStandardError = target
    opts.maxTrials = 100_000_000
    let stream = try EquityCalculator.equity(EquityRequest(players: [try HandRange("AKs, QQ+"), .all]), options: opts)
    var last: EquitySnapshot?
    var count = 0
    for await s in stream { last = s; count += 1 }
    if let l = last {
        print("Stream to ±\(fmt(target * 100, 1))%: \(fmt(seconds(l.elapsed) * 1000, 1)) ms, \(l.samples) trials, \(count) snapshots")
    }
}
}

@MainActor func runSolver() async throws {
    print("")
    print("Push/fold CFR+ solver: 40 stack depths (1.0 to 20.5 bb), 2,000 iterations each")
    let stacks = (0..<40).map { 1.0 + 0.5 * Double($0) }
    let iterations = 2000
    let cpu = CFRPlusSolver()
    // Exploitability checkpoints are excluded from all timings (checkpoint once at the end).
    var t0 = clock.now
    let scalar = stacks.map { cpu.solve(stack: $0, iterations: iterations, checkpointEvery: iterations, backend: .scalar) }
    let scalarWall = seconds(clock.now - t0)
    let scalarSolve = scalar.reduce(0) { $0 + $1.elapsedSeconds }
    t0 = clock.now
    let simd = stacks.map { cpu.solve(stack: $0, iterations: iterations, checkpointEvery: iterations, backend: .simd) }
    let simdSolve = simd.reduce(0) { $0 + $1.elapsedSeconds }
    _ = clock.now - t0
    t0 = clock.now
    let parallel = await cpu.solve(stacks: stacks, iterations: iterations, checkpointEvery: iterations, backend: .simd)
    let parallelWall = seconds(clock.now - t0)
    let iterTotal = Double(stacks.count * iterations)
    print("CPU scalar, 1 thread:        \(fmt(scalarSolve * 1000, 1)) ms  (\(fmt(iterTotal / scalarSolve / 1000, 1))K iterations/s; wall incl. checkpoints \(fmt(scalarWall * 1000, 0)) ms)")
    print("CPU SIMD16, 1 thread:        \(fmt(simdSolve * 1000, 1)) ms  (\(fmt(iterTotal / simdSolve / 1000, 1))K iterations/s) -> \(fmt(scalarSolve / simdSolve, 1))x vs scalar")
    print("CPU SIMD16, \(cores) tasks:       \(fmt(parallelWall * 1000, 1)) ms wall (incl. checkpoint) -> \(fmt(scalarSolve / parallelWall, 1))x vs scalar")
    if let gpu = try? MetalCFRSolver() {
        for kernel in MetalCFRSolver.Kernel.allCases {
            _ = try gpu.solve(stacks: stacks, iterations: 50, checkpointEvery: 50, kernel: kernel) // warm-up
            t0 = clock.now
            let g = try gpu.solve(stacks: stacks, iterations: iterations, checkpointEvery: iterations, kernel: kernel)
            let gpuWall = seconds(clock.now - t0)
            let gpuTime = g[0].elapsedSeconds
            var maxDiff = 0.0
            for d in stacks.indices { for k in 0..<169 { maxDiff = max(maxDiff, abs(g[d].push[k] - simd[d].push[k]), abs(g[d].call[k] - simd[d].call[k])) } }
            print("Metal \(kernel.rawValue) (\(gpu.deviceName)): \(fmt(gpuTime * 1000, 1)) ms GPU, \(fmt(gpuWall * 1000, 1)) ms wall -> \(fmt(scalarSolve / gpuTime, 1))x vs scalar, \(fmt(simdSolve / gpuTime, 1))x vs SIMD 1 thread, \(fmt(parallelWall / gpuWall, 2))x vs SIMD \(cores) tasks; max diff vs CPU \(fmt(maxDiff * 100, 3))%, worst exploitability \(fmt(g.map(\.exploitability).max()!, 4)) mbb")
        }
        // Larger batch: a fine 1/16 bb grid from 1 to 21 bb (320 depths).
        let fine = (0..<320).map { 1.0 + Double($0) / 16 }
        t0 = clock.now
        let cpuFine = await cpu.solve(stacks: fine, iterations: iterations, checkpointEvery: iterations, backend: .simd)
        let cpuFineWall = seconds(clock.now - t0)
        t0 = clock.now
        let gpuFine = try gpu.solve(stacks: fine, iterations: iterations, checkpointEvery: iterations)
        let gpuFineWall = seconds(clock.now - t0)
        print("320 depths x \(iterations) iterations: CPU SIMD \(cores) tasks \(fmt(cpuFineWall * 1000, 0)) ms wall, Metal simd-group kernel \(fmt(gpuFine[0].elapsedSeconds * 1000, 0)) ms GPU / \(fmt(gpuFineWall * 1000, 0)) ms wall (both incl. one exploitability checkpoint per depth) -> \(fmt(cpuFineWall / gpuFineWall, 2))x; worst exploitability CPU \(fmt(cpuFine.map(\.exploitability).max()!, 4)), GPU \(fmt(gpuFine.map(\.exploitability).max()!, 4)) mbb")
    } else {
        print("Metal unavailable on this machine")
    }
    print("Worst CPU exploitability after \(iterations) iterations: \(fmt(parallel.map(\.exploitability).max()!, 4)) mbb/hand")
    // Convergence curve for one depth (the Solver screen shows this).
    let curve = cpu.solve(stack: 10, iterations: 1000, checkpointEvery: 1)
    let marks = [1, 10, 100, 1000]
    print("10 bb exploitability (mbb/hand) at iterations " + marks.map { "\($0): \(fmt(curve.curve[$0 - 1].exploitability, 3))" }.joined(separator: ", "))
    let ten = curve
    print("10 bb Nash: shove \(fmt(ten.pushFraction * 100, 1))% of hands, call \(fmt(ten.callFraction * 100, 1))%")
}

/// Kuhn poker: wall time and iterations until the average strategy's value is within 1e-4 of
/// -1/18 and its exploitability below 1e-4 chips/hand, per CFR variant.
func runToy() {
    print("\nToy games (Kuhn poker, target |value + 1/18| < 1e-4 and exploitability < 1e-4)")
    for variant in [ToyCFR.Variant.vanilla, .cfrPlus, .dcfrDefault] {
        var cfr = ToyCFR(game: .kuhn, variant: variant)
        let clock = ContinuousClock()
        var solve = Duration.zero
        var reached: Int?
        while cfr.iteration < 200_000 {
            let t0 = clock.now
            cfr.run(iterations: 10)
            solve += clock.now - t0
            let avg = cfr.average
            if abs(ToyGame.kuhn.value(avg) - ToyGame.kuhnValue) < 1e-4 && ToyGame.kuhn.exploitability(avg) < 1e-4 {
                reached = cfr.iteration; break
            }
        }
        let name = variant.name.padding(toLength: 22, withPad: " ", startingAt: 0)
        if let reached {
            print("\(name): \(reached) iterations, \(fmt(seconds(solve) * 1000, 2)) ms solve time (excluding checks)")
        } else {
            print("\(name): not reached in 200,000 iterations")
        }
    }
}

/// Iterations each algorithm needs to bring push/fold exploitability under a target, checked
/// every 10 iterations, over 40 stack depths (1.0 to 20.5 bb).
func runDCFR() async {
    let stacks = (0..<40).map { 1.0 + 0.5 * Double($0) }
    let targets = [1.0, 0.1, 0.01]
    print("\nPush/fold iterations to reach exploitability targets (mbb/hand), 40 stack depths, checked every 10 iterations")
    for algorithm in [CFRPlusSolver.Algorithm.cfrPlus, .dcfr] {
        let clock = ContinuousClock()
        let t0 = clock.now
        let solutions = await CFRPlusSolver().solve(stacks: stacks, iterations: 5000, checkpointEvery: 10, algorithm: algorithm)
        let wall = seconds(clock.now - t0)
        var line = algorithm.name.padding(toLength: 20, withPad: " ", startingAt: 0)
        for target in targets {
            let its = solutions.map { s in s.curve.first { $0.exploitability < target }?.iteration }
            let reached = its.compactMap { $0 }.sorted()
            let median = reached.isEmpty ? 0 : reached[reached.count / 2]
            let mean = reached.isEmpty ? 0 : Double(reached.reduce(0, +)) / Double(reached.count)
            line += " | < \(target): median \(median), mean \(fmt(mean, 0)), worst \(reached.last ?? 0) (\(reached.count)/40)"
        }
        print(line + " | wall incl. checks \(fmt(wall, 2)) s")
    }
    #if canImport(Metal)
    if let gpu = try? MetalCFRSolver() {
        for algorithm in [CFRPlusSolver.Algorithm.cfrPlus, .dcfr] {
            let sols = try! gpu.solve(stacks: stacks, iterations: 2000, checkpointEvery: 10, algorithm: algorithm)
            var line = ("Metal " + algorithm.name).padding(toLength: 26, withPad: " ", startingAt: 0)
            for target in targets {
                let reached = sols.compactMap { s in s.curve.first { $0.exploitability < target }?.iteration }
                let mean = reached.isEmpty ? 0 : Double(reached.reduce(0, +)) / Double(reached.count)
                line += " | < \(target): mean \(fmt(mean, 0)) (\(reached.count)/40)"
            }
            print(line + " | GPU \(fmt(sols[0].elapsedSeconds * 1000, 1)) ms for 2,000 iterations x 40 depths")
        }
    }
    #endif
}

/// Process peak physical footprint (what jetsam limits on iOS), in MB.
func peakFootprintMB() -> Double {
    var info = rusage_info_v4()
    let ok = withUnsafeMutablePointer(to: &info) { ptr in
        ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) }
    }
    return ok == 0 ? Double(info.ri_lifetime_max_phys_footprint) / 1_048_576 : .nan
}

// A function, not a global: main.swift globals initialise in source order, after the calls above.
func riverSpots() -> [(name: String, spot: RiverSpot)] {
    func c(_ s: String) -> [Card] { CardSet(parsing: s)!.sortedForDisplay }
    let bb = try! HandRange("22+, A2s+, K2s+, Q4s+, J6s+, T6s+, 96s+, 85s+, 74s+, 63s+, 53s+, 43s, A2o+, K7o+, Q8o+, J8o+, T8o+, 98o")
    let btn = try! HandRange("22+, A2s+, K5s+, Q8s+, J8s+, T8s+, 97s+, 86s+, 75s+, 65s, 54s, A7o+, K9o+, QTo+, JTo")
    return [
        ("Full ranges, Ks9h5c4d2s, 2 sizes", RiverSpot(board: c("Ks9h5c4d2s"), pot: 10, stack: 100, oop: .all, ip: .all)),
        ("Full ranges, Qh8c7c3d2s, 2 sizes", RiverSpot(board: c("Qh8c7c3d2s"), pot: 10, stack: 100, oop: .all, ip: .all)),
        ("Full ranges, 2c7c9cJdKd (iso), 2 sizes", RiverSpot(board: c("2c7c9cJdKd"), pot: 10, stack: 100, oop: .all, ip: .all)),
        ("Full ranges, Ks9h5c4d2s, 1 size", RiverSpot(board: c("Ks9h5c4d2s"), pot: 10, stack: 100, oop: .all, ip: .all,
                                                       config: .init(betSizes: [0.75], raiseSizes: [], maxBets: 2))),
        ("Full ranges, Ks9h5c4d2s, 3 sizes", RiverSpot(board: c("Ks9h5c4d2s"), pot: 10, stack: 100, oop: .all, ip: .all,
                                                        config: .init(betSizes: [0.33, 0.75, 1.5], raiseSizes: [0.75], maxBets: 3))),
        ("BB vs BTN ranges, Ks9h5c4d2s, 2 sizes", RiverSpot(board: c("Ks9h5c4d2s"), pot: 10, stack: 100, oop: bb, ip: btn)),
    ]
}

/// Solve time (DCFR, exploitability checked every 10 iterations, not timed) to 0.3% of the pot.
func runRiver(only: Int?) {
    print("\nRiver solver: DCFR(1.5, 0, 2) to 0.3% pot exploitability, checked every 10 iterations")
    for (i, entry) in riverSpots().enumerated() where only == nil || only == i {
        let clock = ContinuousClock()
        let t0 = clock.now
        let solver = try! RiverSolver(spot: entry.spot)
        let setup = seconds(clock.now - t0)
        let r = solver.solve(targetExploitability: 0.3, maxIterations: 5000, checkEvery: 10)
        let wall = seconds(clock.now - t0)
        let h = solver.handCounts, k = solver.canonicalHandCounts
        print("\(entry.name): hands \(h.oop)/\(h.ip) (canonical \(k.oop)/\(k.ip)), \(solver.decisionNodeCount) decision nodes, tables \(fmt(Double(solver.storageBytes) / 1_048_576, 2)) MB")
        print("   \(r.iterations) iterations, exploitability \(fmt(r.exploitability, 3))% pot, solve \(fmt(r.solveSeconds * 1000, 1)) ms, setup \(fmt(setup * 1000, 1)) ms, wall incl. checks \(fmt(wall * 1000, 1)) ms, process peak footprint \(fmt(peakFootprintMB(), 1)) MB")
    }
}

/// 6-max first-in shove charts: range size per seat, NashConv and solve time.
func runFirstIn() {
    print("\n6-max first-in shove/fold (DCFR, 1,500 iterations, at most one caller)")
    for stack in [10.0, 15.0] {
        for seat in [FirstInShoveSolver.Seat.utg, .hj, .co, .btn, .sb] {
            let clock = ContinuousClock(); let t0 = clock.now
            let s = FirstInShoveSolver.shared.solve(seat: seat, stack: stack)
            let ms = seconds(clock.now - t0) * 1000
            let callers = s.callers.map { "\($0.seat.name) \(fmt($0.call.enumerated().reduce(0) { $0 + $1.element * Double(HandClass(index: $1.offset).comboCount) } / 13.26, 1))%" }.joined(separator: ", ")
            print("\(Int(stack)) bb \(seat.name.padding(toLength: 3, withPad: " ", startingAt: 0)): shove \(fmt(s.pushFraction * 100, 1))% | call: \(callers) | NashConv \(String(format: "%.5f", s.nashConv)) bb | \(fmt(ms, 0)) ms")
        }
    }
}

func streetSpots() -> [(name: String, spot: StreetSpot)] {
    func c(_ s: String) -> [Card] { CardSet(parsing: s)!.sortedForDisplay }
    let bb = try! HandRange("22+, A2s+, K2s+, Q4s+, J6s+, T6s+, 96s+, 85s+, 74s+, 63s+, 53s+, 43s, A2o+, K7o+, Q8o+, J8o+, T8o+, 98o")
    let btn = try! HandRange("22+, A2s+, K5s+, Q8s+, J8s+, T8s+, 97s+, 86s+, 75s+, 65s, 54s, A7o+, K9o+, QTo+, JTo")
    let one = RiverTreeConfig(betSizes: [0.66], raiseSizes: [], allowAllIn: false, maxBets: 1)
    let two = RiverTreeConfig(betSizes: [0.33, 0.75], raiseSizes: [], allowAllIn: true, maxBets: 2)
    return [
        ("Turn, BB vs BTN, 1 size, no raises", StreetSpot(board: c("Ks9h5c4d"), pot: 10, stack: 50, oop: bb, ip: btn, config: one)),
        ("Turn, BB vs BTN, 2 sizes + all-in, 1 raise", StreetSpot(board: c("Ks9h5c4d"), pot: 10, stack: 50, oop: bb, ip: btn, config: two)),
        ("Turn, any two cards, 1 size, no raises", StreetSpot(board: c("Ks9h5c4d"), pot: 10, stack: 50, oop: .all, ip: .all, config: one)),
        ("Flop, narrow ranges, 1 size", StreetSpot(board: c("Kh8d3c"), pot: 10, stack: 20,
            oop: try! HandRange("KK, 88, 33, AK, KQs, QJs, JTs"), ip: try! HandRange("AA, KK, AK, AQs, KQ"), config: one)),
    ]
}

/// Multi-street solves to 0.5% pot exploitability (checked every 10 iterations, not timed).
func runStreet(only: Int?) {
    print("\nMulti-street solver: DCFR(1.5, 0, 2) to 0.5% pot exploitability, checked every 10 iterations, 1 thread")
    for (i, entry) in streetSpots().enumerated() where only == nil || only == i {
        let clock = ContinuousClock(); let t0 = clock.now
        let solver = try! StreetSolver(spot: entry.spot)
        let setup = seconds(clock.now - t0)
        let r = solver.solve(targetExploitability: 0.5, maxIterations: 2000, checkEvery: 10)
        let h = solver.handCounts
        print("\(entry.name): hands \(h.oop)/\(h.ip), \(solver.decisionNodeCount) decision nodes, \(solver.chanceNodeCount) chance nodes, tables \(fmt(Double(solver.storageBytes) / 1_048_576, 1)) MB")
        print("   \(r.iterations) iterations, exploitability \(fmt(r.exploitability, 3))% pot, solve \(fmt(r.solveSeconds, 2)) s, setup \(fmt(setup * 1000, 0)) ms, peak footprint \(fmt(peakFootprintMB(), 0)) MB")
    }
}

/// River solver: CPU (SIMD, sort-and-sweep) vs Metal (batched O(n^2) terminals), 200 iterations.
func runRiverGPU() {
    #if canImport(Metal)
    print("\nRiver solver, 200 DCFR iterations: CPU vs Metal backend (no exploitability checks)")
    for (i, entry) in riverSpots().enumerated() where [0, 4, 5].contains(i) {
        let cpu = try! RiverSolver(spot: entry.spot), gpuSolver = try! RiverSolver(spot: entry.spot)
        let gpu = try! MetalRiverBackend(solver: gpuSolver)
        let clock = ContinuousClock()
        var t0 = clock.now; cpu.iterate(200); let cpuMs = seconds(clock.now - t0) * 1000
        t0 = clock.now; gpu.iterate(200); let gpuWall = seconds(clock.now - t0) * 1000
        let diff = abs(cpu.exploitability() - gpuSolver.exploitability())
        print("\(entry.name): CPU \(fmt(cpuMs, 1)) ms | Metal \(fmt(gpuWall, 1)) ms wall (\(fmt(gpu.gpuSeconds * 1000, 1)) ms GPU) | \(gpu.terminals.count) terminals | exploitability difference \(String(format: "%.4f", diff)) pp | CPU/Metal \(fmt(cpuMs / gpuWall, 2))x")
    }
    #endif
}
