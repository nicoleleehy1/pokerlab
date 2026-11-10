#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum EquityError: Error, Equatable, Sendable {
    case needAtLeastTwoPlayers
    case tooManyPlayers
    case invalidBoard
    case emptyRange(player: Int)
    case noValidDeal
    case tooLargeForExact(estimatedBoards: Double)
}

/// What to compute: one range (or single hand) per player, a board of 0, 3, 4 or 5 cards,
/// and any extra dead cards.
public struct EquityRequest: Hashable, Sendable {
    public var players: [HandRange]
    public var board: CardSet
    public var dead: CardSet

    public init(players: [HandRange], board: CardSet = CardSet(), dead: CardSet = CardSet()) {
        self.players = players; self.board = board; self.dead = dead
    }

    public init(hands: [HoleCards], board: CardSet = CardSet(), dead: CardSet = CardSet()) {
        self.init(players: hands.map { HandRange($0) }, board: board, dead: dead)
    }
}

/// A point-in-time equity estimate. Exact results have zero standard error.
public struct EquitySnapshot: Hashable, Sendable {
    /// Expected pot share per player (wins plus split shares), 0...1.
    public var equities: [Double]
    /// Standard error of each equity estimate (0 when exact).
    public var standardErrors: [Double]
    /// Probability of winning outright / of splitting.
    public var winProbabilities: [Double]
    public var tieProbabilities: [Double]
    /// Monte Carlo trials, or weighted deals enumerated when exact.
    public var samples: Int
    public var isExact: Bool
    public var isFinal: Bool
    public var elapsed: Duration

    public var maxStandardError: Double { standardErrors.max() ?? 0 }
}

// MARK: - Prepared request (flat arrays for the hot loops)

struct PreparedRequest: Sendable {
    let playerCount: Int
    let boardKey: UInt64      // biased key of the board
    let boardMask: UInt64
    let deadMask: UInt64      // board | dead
    let boardNeeded: Int
    // Combos of all players, flattened. Player p owns [start[p], start[p] + count[p]).
    let comboMasks: [UInt64]
    let comboKeys: [UInt64]   // unbiased sum of the two cards' keys
    let comboWeights: [Double]
    let comboCumulative: [Double]
    let start: [Int]
    let count: [Int]
    let uniform: [Bool]

    init(_ request: EquityRequest) throws {
        let n = request.players.count
        guard n >= 2 else { throw EquityError.needAtLeastTwoPlayers }
        guard n <= 10 else { throw EquityError.tooManyPlayers }
        guard [0, 3, 4, 5].contains(request.board.count), !request.board.intersects(request.dead) else {
            throw EquityError.invalidBoard
        }
        let tables = EvaluatorTables.shared
        let dead = request.board.union(request.dead)
        var masks: [UInt64] = [], keys: [UInt64] = [], weights: [Double] = [], cumulative: [Double] = []
        var start: [Int] = [], count: [Int] = [], uniform: [Bool] = []
        for (p, range) in request.players.enumerated() {
            let live = range.removing(dead)
            guard !live.isEmpty else { throw EquityError.emptyRange(player: p) }
            start.append(masks.count); count.append(live.comboCount)
            var acc = 0.0
            for c in live.combos {
                masks.append(c.cards.mask)
                keys.append(tables.cardKeys[Int(c.cards.high.rawValue)] &+ tables.cardKeys[Int(c.cards.low.rawValue)])
                weights.append(c.weight)
                acc += c.weight
                cumulative.append(acc)
            }
            uniform.append(Set(live.combos.map(\.weight)).count == 1)
        }
        playerCount = n
        boardKey = HandEvaluator.shared.key(for: request.board).key
        boardMask = request.board.rawValue
        deadMask = dead.rawValue
        boardNeeded = 5 - request.board.count
        comboMasks = masks; comboKeys = keys; comboWeights = weights; comboCumulative = cumulative
        self.start = start; self.count = count; self.uniform = uniform
        guard hasValidDeal() else { throw EquityError.noValidDeal }
    }

    /// Depth-first search for at least one non-conflicting assignment of hands.
    private func hasValidDeal() -> Bool {
        var steps = 0
        func search(_ p: Int, _ used: UInt64) -> Bool {
            if p == playerCount { return 52 - used.nonzeroBitCount >= boardNeeded }
            for i in start[p]..<(start[p] + count[p]) where comboMasks[i] & used == 0 {
                steps += 1
                if steps > 2_000_000 { return true } // give up proving; sampling will tell
                if search(p + 1, used | comboMasks[i]) { return true }
            }
            return false
        }
        return search(0, deadMask)
    }

    /// Hand assignments times board run-outs: the size of an exact enumeration.
    var estimatedExactBoards: Double {
        var assignments = 1.0
        for c in count { assignments *= Double(c) }
        let remaining = 52 - deadMask.nonzeroBitCount - 2 * playerCount
        return assignments * binomial(remaining, boardNeeded)
    }
}

func binomial(_ n: Int, _ k: Int) -> Double {
    guard k >= 0, k <= n else { return 0 }
    var r = 1.0
    for i in 0..<k { r = r * Double(n - i) / Double(i + 1) }
    return r
}

/// Accumulated outcomes. Doubles hold weighted share sums so exact enumeration with
/// weighted ranges and Monte Carlo can share one type.
struct Tally: Sendable {
    var samples = 0
    var totalWeight = 0.0
    var share: [Double]
    var shareSquared: [Double]
    var wins: [Double]
    var ties: [Double]

    init(players: Int) {
        share = Array(repeating: 0, count: players); shareSquared = share; wins = share; ties = share
    }

    mutating func merge(_ o: Tally) {
        samples += o.samples; totalWeight += o.totalWeight
        for p in share.indices {
            share[p] += o.share[p]; shareSquared[p] += o.shareSquared[p]
            wins[p] += o.wins[p]; ties[p] += o.ties[p]
        }
    }

    func snapshot(exact: Bool, final: Bool, elapsed: Duration) -> EquitySnapshot {
        let w = max(totalWeight, .leastNonzeroMagnitude)
        let eq = share.map { $0 / w }
        let se: [Double] = exact ? eq.map { _ in 0 } : share.indices.map { p in
            let mean = eq[p]
            let variance = max(shareSquared[p] / w - mean * mean, 0)
            return (variance / max(Double(samples), 1)).squareRoot()
        }
        return EquitySnapshot(equities: eq, standardErrors: se,
                              winProbabilities: wins.map { $0 / w }, tieProbabilities: ties.map { $0 / w },
                              samples: samples, isExact: exact, isFinal: final, elapsed: elapsed)
    }
}

// MARK: - Monte Carlo worker

/// One parallel worker: owns its RNG and local counters, shares nothing mutable.
struct MonteCarloWorker: Sendable {
    var rng: Xoshiro256
    let prepared: PreparedRequest

    /// Runs `trials` independent deals. Allocation-free inside the trial loop.
    mutating func run(trials: Int) -> Tally {
        let n = prepared.playerCount
        var tally = Tally(players: n)
        let eval = HandEvaluator.shared
        let cardKeys = eval.cardKeys, cardMasks = eval.cardMasks
        var rng = self.rng
        withUnsafeTemporaryAllocation(of: Int.self, capacity: n) { chosen in
        withUnsafeTemporaryAllocation(of: UInt16.self, capacity: n) { ranks in
        withUnsafeTemporaryAllocation(of: Double.self, capacity: 4 * n) { acc in
            acc.initialize(repeating: 0)
            prepared.comboMasks.withUnsafeBufferPointer { masks in
            prepared.comboKeys.withUnsafeBufferPointer { keys in
            prepared.comboCumulative.withUnsafeBufferPointer { cumulative in
                for _ in 0..<trials {
                    // 1. Deal each player a combo from their range; reject the whole deal on overlap
                    //    so the joint distribution respects card removal exactly.
                    var used: UInt64
                    dealHands: while true {
                        used = prepared.deadMask
                        for p in 0..<n {
                            let s = prepared.start[p], c = prepared.count[p]
                            var idx = s
                            if c > 1 {
                                if prepared.uniform[p] {
                                    idx = s &+ Int(rng.next(below: UInt64(c)))
                                } else {
                                    let target = rng.nextUnit() * cumulative[s + c - 1]
                                    var lo = s, hi = s + c - 1
                                    while lo < hi { let mid = (lo + hi) >> 1; if cumulative[mid] <= target { lo = mid + 1 } else { hi = mid } }
                                    idx = lo
                                }
                            }
                            let m = masks[idx]
                            if m & used != 0 { continue dealHands }
                            used |= m
                            chosen[p] = idx
                        }
                        break
                    }
                    // 2. Complete the board from the remaining deck.
                    var boardKey = prepared.boardKey
                    var boardMask = prepared.boardMask
                    var k = prepared.boardNeeded
                    while k > 0 {
                        let r = Int(rng.next(below: 52))
                        let m = cardMasks[r]
                        if m & used != 0 { continue }
                        used |= m; boardMask |= m; boardKey &+= cardKeys[r]
                        k -= 1
                    }
                    // 3. Showdown.
                    var best: UInt16 = 0
                    var winners = 0
                    for p in 0..<n {
                        let idx = chosen[p]
                        let r = eval.evaluate(HandKey(key: boardKey &+ keys[idx], mask: boardMask | masks[idx])).rawValue
                        ranks[p] = r
                        if r > best { best = r; winners = 1 } else if r == best { winners &+= 1 }
                    }
                    let share = 1.0 / Double(winners)
                    for p in 0..<n where ranks[p] == best {
                        acc[p] += share
                        acc[n + p] += share * share
                        if winners == 1 { acc[2 * n + p] += 1 } else { acc[3 * n + p] += 1 }
                    }
                }
            } } }
            for p in 0..<n {
                tally.share[p] = acc[p]; tally.shareSquared[p] = acc[n + p]
                tally.wins[p] = acc[2 * n + p]; tally.ties[p] = acc[3 * n + p]
            }
        } } }
        tally.samples = trials
        tally.totalWeight = Double(trials)
        self.rng = rng
        return tally
    }
}

// MARK: - Exact enumeration

struct ExactEnumerator {
    let prepared: PreparedRequest
    let eval = HandEvaluator.shared

    /// All non-conflicting hand assignments (combo index per player) with their weight.
    func assignments() -> [(combos: [Int], weight: Double, used: UInt64)] {
        var out: [(combos: [Int], weight: Double, used: UInt64)] = []
        var current: [Int] = []
        func go(_ p: Int, _ used: UInt64, _ w: Double) {
            if p == prepared.playerCount { out.append((current, w, used)); return }
            for i in prepared.start[p]..<(prepared.start[p] + prepared.count[p]) where prepared.comboMasks[i] & used == 0 {
                current.append(i)
                go(p + 1, used | prepared.comboMasks[i], w * prepared.comboWeights[i])
                current.removeLast()
            }
        }
        go(0, prepared.deadMask, 1)
        return out
    }

    /// Enumerates every board completion for one assignment, optionally fixing the first
    /// extra card to `firstIndex` within the remaining-card list (for parallel splitting).
    func run(assignment: [Int], weight: Double, used: UInt64, firstIndex: Int?, into tally: inout Tally) {
        let n = prepared.playerCount
        var remaining: [UInt8] = []
        for raw in 0..<52 where eval.cardMasks[raw] & used == 0 { remaining.append(UInt8(raw)) }
        let handKeys = assignment.map { prepared.comboKeys[$0] }
        let handMasks = assignment.map { prepared.comboMasks[$0] }
        var share = [Double](repeating: 0, count: n), wins = share, ties = share
        var ranks = [UInt16](repeating: 0, count: n)
        var boards = 0

        func leaf(_ key: UInt64, _ mask: UInt64) {
            var best: UInt16 = 0, winners = 0
            for p in 0..<n {
                let r = eval.evaluate(HandKey(key: key &+ handKeys[p], mask: mask | handMasks[p])).rawValue
                ranks[p] = r
                if r > best { best = r; winners = 1 } else if r == best { winners += 1 }
            }
            let s = 1.0 / Double(winners)
            for p in 0..<n where ranks[p] == best {
                share[p] += s
                if winners == 1 { wins[p] += 1 } else { ties[p] += 1 }
            }
            boards += 1
        }
        func recurse(_ from: Int, _ depth: Int, _ key: UInt64, _ mask: UInt64) {
            if depth == 0 { leaf(key, mask); return }
            var i = from
            while i <= remaining.count - depth {
                let raw = Int(remaining[i])
                recurse(i + 1, depth - 1, key &+ eval.cardKeys[raw], mask | eval.cardMasks[raw])
                i += 1
            }
        }
        let need = prepared.boardNeeded
        if need == 0 {
            leaf(prepared.boardKey, prepared.boardMask)
        } else if let first = firstIndex {
            let raw = Int(remaining[first])
            recurse(first + 1, need - 1, prepared.boardKey &+ eval.cardKeys[raw], prepared.boardMask | eval.cardMasks[raw])
        } else {
            recurse(0, need, prepared.boardKey, prepared.boardMask)
        }
        for p in 0..<n {
            tally.share[p] += share[p] * weight
            tally.shareSquared[p] += share[p] * weight // unused for exact results
            tally.wins[p] += wins[p] * weight
            tally.ties[p] += ties[p] * weight
        }
        tally.samples += boards
        tally.totalWeight += Double(boards) * weight
    }
}

// MARK: - Public API

/// Equity engine. Stateless and `Sendable`; every call owns its work.
public enum EquityCalculator {
    /// Number of active CPU cores (used as the default parallelism).
    public static var defaultParallelism: Int {
        #if canImport(Darwin) || canImport(Glibc)
        return max(1, Int(sysconf(Int32(_SC_NPROCESSORS_ONLN))))
        #else
        return 4
        #endif
    }

    /// Size of the exact enumeration (hand assignments x board run-outs).
    public static func estimatedExactBoards(_ request: EquityRequest) throws -> Double {
        try PreparedRequest(request).estimatedExactBoards
    }

    /// Exact equity by enumerating every hand assignment and board, split across a TaskGroup.
    /// Checks for cancellation between work items.
    public static func exact(_ request: EquityRequest,
                             parallelism: Int = defaultParallelism,
                             limit: Double = 5e9) async throws -> EquitySnapshot {
        let clock = ContinuousClock()
        let start = clock.now
        let prepared = try PreparedRequest(request)
        guard prepared.estimatedExactBoards <= limit else {
            throw EquityError.tooLargeForExact(estimatedBoards: prepared.estimatedExactBoards)
        }
        let enumerator = ExactEnumerator(prepared: prepared)
        let assignments = enumerator.assignments()
        guard !assignments.isEmpty else { throw EquityError.noValidDeal }
        // Work items: (assignment, first board card index) so even one heads-up spot splits well.
        var jobs: [(Int, Int?)] = []
        let remainingCount = 52 - prepared.deadMask.nonzeroBitCount - 2 * prepared.playerCount
        for a in assignments.indices {
            if prepared.boardNeeded == 0 { jobs.append((a, nil)) }
            else { for f in 0...(remainingCount - prepared.boardNeeded) { jobs.append((a, f)) } }
        }
        let workItems = jobs
        let workers = max(1, min(parallelism, workItems.count))
        let total = try await withThrowingTaskGroup(of: Tally.self) { group in
            for w in 0..<workers {
                group.addTask {
                    var tally = Tally(players: prepared.playerCount)
                    var j = w
                    while j < workItems.count {
                        try Task.checkCancellation()
                        let (a, f) = workItems[j]
                        let asg = assignments[a]
                        enumerator.run(assignment: asg.combos, weight: asg.weight, used: asg.used, firstIndex: f, into: &tally)
                        j += workers
                    }
                    return tally
                }
            }
            var merged = Tally(players: prepared.playerCount)
            for try await t in group { merged.merge(t) }
            return merged
        }
        return total.snapshot(exact: true, final: true, elapsed: clock.now - start)
    }

    /// Monte Carlo equity: `trials` deals split across `parallelism` child tasks, each with
    /// its own seeded RNG. Deterministic for a given seed and parallelism.
    public static func monteCarlo(_ request: EquityRequest,
                                  trials: Int,
                                  seed: UInt64 = 0x5EED,
                                  parallelism: Int = defaultParallelism) async throws -> EquitySnapshot {
        let clock = ContinuousClock()
        let start = clock.now
        let prepared = try PreparedRequest(request)
        let workers = max(1, parallelism)
        let tallies = try await withThrowingTaskGroup(of: (Int, Tally).self) { group in
            for w in 0..<workers {
                let share = trials / workers + (w < trials % workers ? 1 : 0)
                group.addTask {
                    var worker = MonteCarloWorker(rng: Xoshiro256(seed: seed, stream: w), prepared: prepared)
                    var tally = Tally(players: prepared.playerCount)
                    var done = 0
                    while done < share {
                        try Task.checkCancellation()
                        let batch = min(16_384, share - done)
                        tally.merge(worker.run(trials: batch))
                        done += batch
                    }
                    return (w, tally)
                }
            }
            var results = [Tally?](repeating: nil, count: workers)
            for try await (w, t) in group { results[w] = t }
            return results.compactMap { $0 }
        }
        var merged = Tally(players: prepared.playerCount)
        for t in tallies { merged.merge(t) } // fixed order: reproducible floating-point sums
        return merged.snapshot(exact: false, final: true, elapsed: clock.now - start)
    }

    public struct StreamOptions: Sendable {
        /// Use exact enumeration when it needs at most this many board run-outs.
        public var exactThreshold: Double = 3_000_000
        public var maxTrials: Int = 4_000_000
        /// Stop early once every player's standard error is at or below this.
        public var targetStandardError: Double = 0.0005
        public var minimumTrials: Int = 20_000
        public var trialsPerWorkerPerBatch: Int = 8_192
        public var parallelism: Int = EquityCalculator.defaultParallelism
        public var seed: UInt64 = 0x5EED
        public init() {}
    }

    /// Live equity: yields a snapshot after every parallel batch so a UI can draw convergence.
    /// Small spots are solved exactly and yield one final snapshot. Cancelling the consuming
    /// task (or dropping the stream) cancels the computation within one batch.
    public static func equity(_ request: EquityRequest,
                              options: StreamOptions = StreamOptions()) throws -> AsyncStream<EquitySnapshot> {
        let prepared = try PreparedRequest(request)
        let (stream, continuation) = AsyncStream.makeStream(of: EquitySnapshot.self, bufferingPolicy: .bufferingNewest(8))
        let task = Task {
            if prepared.estimatedExactBoards <= options.exactThreshold {
                if let snap = try? await exact(request, parallelism: options.parallelism) {
                    continuation.yield(snap)
                }
                continuation.finish()
                return
            }
            let clock = ContinuousClock()
            let start = clock.now
            let workers = max(1, options.parallelism)
            var states = (0..<workers).map {
                MonteCarloWorker(rng: Xoshiro256(seed: options.seed, stream: $0), prepared: prepared)
            }
            var total = Tally(players: prepared.playerCount)
            while !Task.isCancelled {
                let current = states
                let batch = options.trialsPerWorkerPerBatch
                let results = await withTaskGroup(of: (Int, MonteCarloWorker, Tally).self) { group in
                    for (i, worker) in current.enumerated() {
                        group.addTask {
                            var w = worker
                            let t = w.run(trials: batch)
                            return (i, w, t)
                        }
                    }
                    var out = [(MonteCarloWorker, Tally)?](repeating: nil, count: workers)
                    for await (i, w, t) in group { out[i] = (w, t) }
                    return out.compactMap { $0 }
                }
                if Task.isCancelled { break }
                for (i, r) in results.enumerated() { states[i] = r.0; total.merge(r.1) }
                var snap = total.snapshot(exact: false, final: false, elapsed: clock.now - start)
                let done = total.samples >= options.maxTrials
                    || (total.samples >= options.minimumTrials && snap.maxStandardError <= options.targetStandardError)
                snap.isFinal = done
                continuation.yield(snap)
                if done { break }
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }
}
