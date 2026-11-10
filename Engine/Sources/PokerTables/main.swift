import PokerCore
#if canImport(Darwin)
import Darwin
#endif

// PokerTables: generates Sources/PokerSolver/Resources/PreflopEquity.bin, the exact
// all-in preflop equity of every starting-hand class against every other.
//
// For each ordered class pair (i, j) the value is the average equity of class i over every
// non-conflicting combo pair, each solved by full enumeration of all 1,712,304 boards.
// Suit isomorphism (24 suit permutations) collapses the 812,175 distinct combo pairs to a
// few tens of thousands of canonical matchups, which are solved in parallel.
//
// Usage (from the Engine directory):
//   swift run -c release PokerTables offsets   -> Sources/PokerCore/RankHashOffsets.swift
//   swift run -c release PokerTables preflop   -> Sources/PokerSolver/Resources/PreflopEquity.bin

let perms: [[UInt8]] = {
    var out: [[UInt8]] = []
    for a in 0..<4 { for b in 0..<4 where b != a { for c in 0..<4 where c != a && c != b {
        out.append([UInt8(a), UInt8(b), UInt8(c), UInt8(6 - a - b - c)])
    } } }
    return out
}()

func mapped(_ c: Card, _ p: [UInt8]) -> UInt8 { (c.rawValue & ~3) | p[Int(c.rawValue & 3)] }

/// Canonical key of an ordered matchup (hero, villain) under suit relabelling.
func canonical(_ h: HoleCards, _ v: HoleCards) -> UInt32 {
    var best = UInt32.max
    for p in perms {
        var a = mapped(h.high, p), b = mapped(h.low, p), c = mapped(v.high, p), d = mapped(v.low, p)
        if a < b { swap(&a, &b) }
        if c < d { swap(&c, &d) }
        let key = UInt32(a) << 24 | UInt32(b) << 16 | UInt32(c) << 8 | UInt32(d)
        best = min(best, key)
    }
    return best
}

func decode(_ key: UInt32) -> (HoleCards, HoleCards) {
    let a = Card(rawValue: UInt8(key >> 24)), b = Card(rawValue: UInt8((key >> 16) & 0xFF))
    let c = Card(rawValue: UInt8((key >> 8) & 0xFF)), d = Card(rawValue: UInt8(key & 0xFF))
    return (HoleCards(a, b), HoleCards(c, d))
}

func writeFile(_ path: String, _ bytes: [UInt8]) {
    guard let file = fopen(path, "wb") else { fatalError("cannot open \(path)") }
    _ = bytes.withUnsafeBytes { fwrite($0.baseAddress, 1, $0.count, file) }
    fclose(file)
}

let command = CommandLine.arguments.dropFirst().first ?? "help"
let clock = ContinuousClock()
let start = clock.now

switch command {
case "offsets":
    let path = "Sources/PokerCore/RankHashOffsets.swift"
    writeFile(path, Array(EvaluatorTables.generateRowOffsetsSource().utf8))
    print("Wrote \(path) in \(clock.now - start)")
case "preflop":
    try await generatePreflop(outPath: "Sources/PokerSolver/Resources/PreflopEquity.bin")
default:
    print("usage: PokerTables offsets | preflop")
}

func generatePreflop(outPath: String) async throws {

// 1. Canonical matchups needed for all class pairs.
var canonicalSet = Set<UInt32>()
var pairKeys = [[UInt32]](repeating: [], count: 169 * 169)
for i in 0..<169 {
    let ci = HandClass(index: i).combos
    for j in 0..<169 {
        let cj = HandClass(index: j).combos
        var keys: [UInt32] = []
        for h in ci { for v in cj where h.mask & v.mask == 0 { keys.append(canonical(h, v)) } }
        pairKeys[i * 169 + j] = keys
        canonicalSet.formUnion(keys)
    }
}
let canon = Array(canonicalSet).sorted()
print("Canonical matchups: \(canon.count)")

// 2. Solve each canonical matchup exactly, in parallel.
let cores = EquityCalculator.defaultParallelism
let results: [UInt32: Double] = try await withThrowingTaskGroup(of: [(UInt32, Double)].self) { group in
    for w in 0..<cores {
        group.addTask {
            var out: [(UInt32, Double)] = []
            var k = w
            while k < canon.count {
                let (h, v) = decode(canon[k])
                let r = try await EquityCalculator.exact(EquityRequest(hands: [h, v]), parallelism: 1)
                out.append((canon[k], r.equities[0]))
                k += cores
            }
            return out
        }
    }
    var all: [UInt32: Double] = [:]
    var done = 0
    for try await part in group {
        for (k, e) in part { all[k] = e }
        done += 1
        print("  worker \(done)/\(cores) finished")
    }
    return all
}

// 3. Average per class pair and write little-endian Float32 [169 * 169].
var matrix = [Float](repeating: 0, count: 169 * 169)
for idx in 0..<(169 * 169) {
    let keys = pairKeys[idx]
    matrix[idx] = Float(keys.reduce(0.0) { $0 + results[$1]! } / Double(keys.count))
}
var bytes: [UInt8] = Array("PLEQ".utf8) + [1, 0, 0, 0] // magic + version 1
for f in matrix { withUnsafeBytes(of: f.bitPattern.littleEndian) { bytes.append(contentsOf: $0) } }
writeFile(outPath, bytes)
let elapsed = clock.now - start
print("Wrote \(outPath) (\(bytes.count) bytes) in \(elapsed)")
print("Check: AA vs KK = \(matrix[HandClass("AA")!.index * 169 + HandClass("KK")!.index]), AKs vs QQ = \(matrix[HandClass("AKs")!.index * 169 + HandClass("QQ")!.index]), 72o vs AA = \(matrix[HandClass("72o")!.index * 169 + HandClass("AA")!.index])")
}
