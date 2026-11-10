import PokerCore

// PokerBench: prints throughput numbers for BENCHMARKS.md. Run with:
//   swift run -c release PokerBench
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
var checksum: UInt64 = 0
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
func enumerateAll(firsts: some Sequence<Int>) -> UInt64 {
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
print("")
print("checksum \(checksum)")
