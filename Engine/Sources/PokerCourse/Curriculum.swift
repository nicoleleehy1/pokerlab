import PokerCore

/// Concepts the adaptive layer tracks (one or more per unit).
public enum Concept: String, CaseIterable, Hashable, Sendable, Codable {
    case requiredEquity, callOrFold
    case equityVsHand, equityVsRange
    case openingRanges
    case gtoBasics
    case mdf, bluffRatio, bluffCatching
    case pushFold, callShove
    case rangeAdvantage
    case riverPlay
    case exploits
    case icm

    public var title: String {
        switch self {
        case .requiredEquity: "Required equity"
        case .callOrFold: "Call or fold"
        case .equityVsHand: "Equity vs a hand"
        case .equityVsRange: "Equity vs a range"
        case .openingRanges: "Opening ranges"
        case .gtoBasics: "What GTO means"
        case .mdf: "Minimum defence"
        case .bluffRatio: "Bluff ratio"
        case .bluffCatching: "Bluff-catching"
        case .pushFold: "Push or fold"
        case .callShove: "Calling shoves"
        case .rangeAdvantage: "Range advantage"
        case .riverPlay: "River strategy"
        case .exploits: "Exploits"
        case .icm: "ICM"
        }
    }
}

/// A lesson: ~10 generated questions drawn round-robin from its templates.
public struct Lesson: Hashable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let templates: [TemplateID]
    public let questionCount: Int

    public init(_ id: String, _ title: String, _ templates: [TemplateID], questions: Int = 10) {
        self.id = id; self.title = title; self.templates = templates; self.questionCount = questions
    }
}

public struct CourseUnit: Hashable, Sendable, Identifiable {
    public let number: Int
    public let title: String
    public let summary: String
    public let lessons: [Lesson]
    /// False while a unit's generators need an engine piece that isn't built yet.
    public let isAvailable: Bool
    public var id: Int { number }
}

/// The ten units from docs/research/gto-learning-research.md: EV and pot odds, through
/// preflop and toy games, to postflop structure, exploits and ICM.
public enum Curriculum {
    public static let units: [CourseUnit] = [
        CourseUnit(number: 1, title: "EV and pot odds", summary: "Maximise EV, not how often you win.", lessons: [
            Lesson("u1-l1", "Price of a call", [.requiredEquity]),
            Lesson("u1-l2", "Call or fold", [.callOrFold]),
            Lesson("u1-l3", "Mixed review", [.requiredEquity, .callOrFold]),
        ], isAvailable: true),
        CourseUnit(number: 2, title: "Equity vs ranges", summary: "How often your hand wins, against a hand and a range.", lessons: [
            Lesson("u2-l1", "Hand vs hand", [.equityVsHand]),
            Lesson("u2-l2", "Hand vs range", [.equityVsRange]),
            Lesson("u2-l3", "Mixed review", [.equityVsHand, .equityVsRange]),
        ], isAvailable: true),
        CourseUnit(number: 3, title: "Preflop foundations", summary: "Open wider in later position; raise, don't limp.", lessons: [
            Lesson("u3-l1", "Position and range width", [.openingWidth]),
            Lesson("u3-l2", "Open or fold", [.openOrFold]),
        ], isAvailable: true),
        CourseUnit(number: 4, title: "What GTO is", summary: "Unexploitable is not the same as maximum profit.", lessons: [
            Lesson("u4-l1", "Kuhn poker", [.kuhn]),
        ], isAvailable: true),
        CourseUnit(number: 5, title: "Toy games and indifference", summary: "MDF, alpha and bluff ratios from one bet size.", lessons: [
            Lesson("u5-l1", "Minimum defence", [.mdf]),
            Lesson("u5-l2", "Bluff ratio", [.bluffRatio]),
            Lesson("u5-l3", "Catching bluffs", [.bluffCatch]),
        ], isAvailable: true),
        CourseUnit(number: 6, title: "Push or fold", summary: "Short-stack Nash shoves and calls, solved live.", lessons: [
            Lesson("u6-l1", "Shoving", [.pushFold]),
            Lesson("u6-l2", "Calling shoves", [.callShove]),
            Lesson("u6-l3", "Mixed review", [.pushFold, .callShove]),
        ], isAvailable: true),
        CourseUnit(number: 7, title: "Postflop structure", summary: "Range and nut advantage decide how often and how big.", lessons: [
            Lesson("u7-l1", "Who has the advantage?", [.rangeAdvantage]),
            Lesson("u7-l2", "River bet or check", [.riverBet]),
        ], isAvailable: RiverCapability.isAvailable),
        CourseUnit(number: 8, title: "Advanced balance", summary: "Polarised ranges, blockers and mixed strategies.", lessons: [
            Lesson("u8-l1", "Facing a river bet", [.riverDefend]),
            Lesson("u8-l2", "Bet, check or mix", [.riverBet, .riverDefend]),
        ], isAvailable: RiverCapability.isAvailable),
        CourseUnit(number: 9, title: "Exploits", summary: "When a player's leaks change your best response.", lessons: [
            Lesson("u9-l1", "Against a nit", [.exploitNit]),
            Lesson("u9-l2", "Against a station", [.exploitStation]),
        ], isAvailable: RiverCapability.isAvailable),
        CourseUnit(number: 10, title: "ICM and caveats", summary: "Chips aren't money near the bubble.", lessons: [
            Lesson("u10-l1", "Risk premium", [.icmCall]),
            Lesson("u10-l2", "GTO's caveats", [.caveats]),
        ], isAvailable: true),
    ]

    public static var lessons: [Lesson] { units.flatMap(\.lessons) }

    public static func unit(containing lessonID: String) -> CourseUnit? {
        units.first { $0.lessons.contains { $0.id == lessonID } }
    }

    public static func lesson(_ id: String) -> Lesson? { lessons.first { $0.id == id } }

    /// Generates one question per template in `plan` (an adaptive review session).
    public static func questions(plan: [TemplateID], seed: UInt64) async throws -> [Question] {
        var out: [Question] = []
        for (i, t) in plan.enumerated() { out.append(try await t.generate(seed: seed &+ UInt64(i) &* 0x9E37_79B9_7F4A_7C15)) }
        return out
    }

    /// Templates the learner has reached: every lesson that is done or current.
    public static func unlockedTemplates(_ progress: CourseProgress) -> [TemplateID] {
        var seen: [TemplateID] = []
        for item in progress.path() where item.status != .locked {
            for t in item.lesson.templates where !seen.contains(t) { seen.append(t) }
        }
        return seen
    }

    /// Generates a lesson's questions. Deterministic for a given seed.
    public static func questions(for lesson: Lesson, seed: UInt64) async throws -> [Question] {
        var out: [Question] = []
        for i in 0..<lesson.questionCount {
            let template = lesson.templates[i % lesson.templates.count]
            out.append(try await template.generate(seed: seed &+ UInt64(i) &* 0x9E37_79B9_7F4A_7C15))
        }
        return out
    }
}

/// Units 7-9 need the river solver (PokerSolver.RiverSolver), which this build has.
public enum RiverCapability {
    public static let isAvailable = true
}
