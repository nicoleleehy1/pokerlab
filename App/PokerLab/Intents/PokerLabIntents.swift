import AppIntents
import PokerCore
import PokerTraining

/// App Intents metadata is extracted at build time, so the enum must live in the app target.
enum DrillChoice: String, AppEnum {
    case equityQuiz, potOdds, rangeTrainer

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Drill"
    static let caseDisplayRepresentations: [DrillChoice: DisplayRepresentation] = [
        .equityQuiz: "Equity Quiz", .potOdds: "Pot Odds", .rangeTrainer: "Range Trainer",
    ]

    var kind: DrillKind {
        switch self {
        case .equityQuiz: .equityQuiz
        case .potOdds: .potOdds
        case .rangeTrainer: .rangeTrainer
        }
    }
}

/// Opens a drill session.
struct StartDrillIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Drill"
    static let description = IntentDescription("Starts a 10-spot PokerLab training session.")
    static let openAppWhenRun = true

    @Parameter(title: "Drill", default: .equityQuiz)
    var drill: DrillChoice

    static var parameterSummary: some ParameterSummary { Summary("Start \(\.$drill)") }

    @MainActor
    func perform() async throws -> some IntentResult {
        AppRouter.shared.open(.drill(drill.kind))
        return .result()
    }
}

/// Opens today's daily drill.
struct OpenDailyDrillIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Daily Drill"
    static let description = IntentDescription("Opens today's equity spot, the same for every player.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        AppRouter.shared.open(.dailyDrill)
        return .result()
    }
}

/// Computes equity without opening the app, for Siri and Shortcuts.
struct CalculateEquityIntent: AppIntent {
    static let title: LocalizedStringResource = "Calculate Poker Equity"
    static let description = IntentDescription("Calculates how often a hand wins against a hand or range, on an optional board.")

    @Parameter(title: "Your hand", description: "Two cards, for example AsKd.")
    var hand: String

    @Parameter(title: "Opponent", description: "A hand (QhQc) or a range (TT+, AQs+). Leave as random for any two cards.", default: "random")
    var opponent: String

    @Parameter(title: "Board", description: "Zero, three, four or five cards, for example Td7c2h.", default: "")
    var board: String

    static var parameterSummary: some ParameterSummary {
        Summary("Equity of \(\.$hand) against \(\.$opponent)") { \.$board }
    }

    enum Failure: Error, CustomLocalizedStringResourceConvertible {
        case badHand, badOpponent(String), badBoard, overlap
        var localizedStringResource: LocalizedStringResource {
            switch self {
            case .badHand: "Your hand must be two different cards, like AsKd."
            case .badOpponent(let m): "I couldn't read the opponent: \(m)"
            case .badBoard: "The board must be 0, 3, 4 or 5 cards, like Td7c2h."
            case .overlap: "The same card appears twice."
            }
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<Double> & ProvidesDialog {
        let spot = try Self.parse(hand: hand, opponent: opponent, board: board)
        let request = EquityRequest(players: [HandRange(spot.hero), spot.villain], board: spot.board)
        let snapshot: EquitySnapshot
        if (try? EquityCalculator.estimatedExactBoards(request)) ?? .infinity <= 3_000_000 {
            snapshot = try await EquityCalculator.exact(request)
        } else {
            snapshot = try await EquityCalculator.monteCarlo(request, trials: 400_000)
        }
        let equity = snapshot.equities[0]
        let pct = (equity * 100).formatted(.number.precision(.fractionLength(1)))
        let how = snapshot.isExact ? "exactly" : "about"
        return .result(value: equity, dialog: "\(spot.hero.description) has \(how) \(pct)% equity.")
    }

    struct Spot { let hero: HoleCards; let villain: HandRange; let board: CardSet }

    static func parse(hand: String, opponent: String, board: String) throws -> Spot {
        guard let heroSet = CardSet(parsing: hand), heroSet.count == 2 else { throw Failure.badHand }
        let heroCards = Array(heroSet)
        let hero = HoleCards(heroCards[0], heroCards[1])
        let boardSet: CardSet
        if board.trimmingCharacters(in: .whitespaces).isEmpty { boardSet = CardSet() }
        else {
            guard let b = CardSet(parsing: board), [0, 3, 4, 5].contains(b.count) else { throw Failure.badBoard }
            boardSet = b
        }
        guard heroSet.rawValue & boardSet.rawValue == 0 else { throw Failure.overlap }
        let trimmed = opponent.trimmingCharacters(in: .whitespaces)
        var villain: HandRange
        if trimmed.isEmpty || trimmed.lowercased() == "random" { villain = .all }
        else {
            do { villain = try HandRange(trimmed) } catch { throw Failure.badOpponent(String(describing: error)) }
        }
        villain = villain.removing(CardSet(rawValue: heroSet.rawValue | boardSet.rawValue))
        guard !villain.isEmpty else { throw Failure.overlap }
        return Spot(hero: hero, villain: villain, board: boardSet)
    }
}

struct PokerLabShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: OpenDailyDrillIntent(),
                    phrases: ["Open the \(.applicationName) daily drill", "Today's \(.applicationName) spot"],
                    shortTitle: "Daily Drill", systemImageName: "calendar")
        AppShortcut(intent: StartDrillIntent(),
                    phrases: ["Start a \(\.$drill) in \(.applicationName)", "Train with \(.applicationName)"],
                    shortTitle: "Start Drill", systemImageName: "target")
        AppShortcut(intent: CalculateEquityIntent(),
                    phrases: ["Calculate equity in \(.applicationName)"],
                    shortTitle: "Calculate Equity", systemImageName: "percent")
    }
}
