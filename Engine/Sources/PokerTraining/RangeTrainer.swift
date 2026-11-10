import PokerCore
import PokerSolver

/// Paint a 13x13 range and compare it to the solver's heads-up push/fold Nash chart.
public struct RangeTrainerSpot: Hashable, Sendable, Codable {
    public enum Role: String, Codable, Sendable { case smallBlindShove, bigBlindCall }
    public let category: SkillCategory
    public let role: Role
    public let stack: Double

    public var prompt: String {
        switch role {
        case .smallBlindShove: "Paint the small blind's shoving range at \(Int(stack)) bb"
        case .bigBlindCall: "Paint the big blind's calling range against a shove at \(Int(stack)) bb"
        }
    }
}

public struct RangeComparison: Hashable, Sendable {
    /// Combo-weighted agreement with the reference, 0...1.
    public let accuracy: Double
    public let missed: [HandClass]   // in reference, not painted
    public let extra: [HandClass]    // painted, not in reference
    public let reference: Set<HandClass>
}

public enum RangeTrainer {
    public static let categories: [SkillCategory] = [.pushRanges, .callRanges]
    public static let stacks: [Double] = [5, 8, 10, 12, 15, 20]

    public static func generate(_ category: SkillCategory, seed: UInt64) -> RangeTrainerSpot {
        var rng = Xoshiro256(seed: seed)
        let stack = stacks[Int(rng.next(below: UInt64(stacks.count)))]
        return RangeTrainerSpot(category: category, role: category == .callRanges ? .bigBlindCall : .smallBlindShove, stack: stack)
    }

    /// Reference: classes the Nash strategy plays at least half the time.
    public static func reference(for spot: RangeTrainerSpot, charts: PushFoldCharts) async -> Set<HandClass> {
        let sol = await charts.solution(stack: spot.stack)
        let freq = spot.role == .smallBlindShove ? sol.push : sol.call
        return Set(HandClass.all.filter { freq[$0.index] >= 0.5 })
    }

    public static func compare(painted: Set<HandClass>, reference: Set<HandClass>) -> RangeComparison {
        var agree = 0
        for hc in HandClass.all where painted.contains(hc) == reference.contains(hc) { agree += hc.comboCount }
        return RangeComparison(accuracy: Double(agree) / 1326,
                               missed: reference.subtracting(painted).sorted(),
                               extra: painted.subtracting(reference).sorted(),
                               reference: reference)
    }

    public static func grade(_ c: RangeComparison) -> Grade {
        let pct = c.accuracy * 100
        return Grade(isCorrect: pct >= 90, errorPoints: 100 - pct, points: Int(pct.rounded()),
                     verdict: pct >= 95 ? .spotOn : pct >= 90 ? .close : pct >= 80 ? .off : .wayOff)
    }
}

/// Caches solved push/fold charts by stack depth (an actor so drills and the Solver screen share it).
public actor PushFoldCharts {
    public static let shared = PushFoldCharts()
    private var cache: [Double: PushFoldSolution] = [:]
    private let solver = CFRPlusSolver()
    public let iterations: Int

    public init(iterations: Int = 1500) { self.iterations = iterations }

    public func solution(stack: Double) -> PushFoldSolution {
        if let s = cache[stack] { return s }
        let s = solver.solve(stack: stack, iterations: iterations, checkpointEvery: 50)
        cache[stack] = s
        return s
    }
}
