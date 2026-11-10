import SwiftUI
import PokerCore

/// State of the Equity Lab. Owns the running equity computation: any change to the cards
/// cancels it (within one batch) and starts a new stream. UI updates are throttled to ~30 Hz.
@MainActor @Observable
final class EquityLabModel {
    enum VillainMode: String, CaseIterable, Identifiable { case hand = "Hand", range = "Range"; var id: Self { self } }
    enum Slot: Hashable, Identifiable {
        case hero(Int), villain(Int), board(Int)
        var id: String { "\(self)" }
        var title: String {
            switch self {
            case .hero: "Your hand"
            case .villain: "Villain's hand"
            case .board(let i): i < 3 ? "Flop" : (i == 3 ? "Turn" : "River")
            }
        }
    }
    struct ConvergencePoint: Identifiable, Equatable {
        var id: Int { trials }
        let trials: Int
        let equity: Double
        let low: Double
        let high: Double
    }

    var hero: [Card?] = [nil, nil]
    var villain: [Card?] = [nil, nil]
    var board: [Card?] = Array(repeating: nil, count: 5)
    var villainMode: VillainMode = .range
    var villainRangeText = "random"
    var pickerSlot: Slot?

    private(set) var snapshot: EquitySnapshot?
    private(set) var convergence: [ConvergencePoint] = []
    private(set) var isRunning = false
    private(set) var message: String?
    private(set) var rangeError: String?
    /// Incremented on each finished computation (drives a subtle haptic).
    private(set) var completedRuns = 0

    private var task: Task<Void, Never>?
    private var generation = 0

    var usedCards: CardSet {
        var s = CardSet()
        for c in hero + board { if let c { s.insert(c) } }
        if villainMode == .hand { for c in villain { if let c { s.insert(c) } } }
        return s
    }

    func card(at slot: Slot) -> Card? {
        switch slot {
        case .hero(let i): hero[i]
        case .villain(let i): villain[i]
        case .board(let i): board[i]
        }
    }

    func set(_ card: Card?, at slot: Slot) {
        switch slot {
        case .hero(let i): hero[i] = card
        case .villain(let i): villain[i] = card
        case .board(let i): board[i] = card
        }
        recompute()
    }

    func clear() {
        hero = [nil, nil]; villain = [nil, nil]; board = Array(repeating: nil, count: 5)
        recompute()
    }

    /// Loads a preset spot (used by App Intents and the camera).
    func load(hero h: [Card], villain v: HandRange?, villainCards: [Card] = [], board b: [Card]) {
        hero = [h.first, h.dropFirst().first]
        if let v { villainMode = .range; villainRangeText = v.description.isEmpty ? "random" : v.description }
        if !villainCards.isEmpty { villainMode = .hand; villain = [villainCards.first, villainCards.dropFirst().first] }
        board = (0..<5).map { $0 < b.count ? b[$0] : nil }
        recompute()
    }

    func recompute() {
        task?.cancel()
        task = nil
        generation += 1
        isRunning = false
        message = nil
        rangeError = nil

        guard let h1 = hero[0], let h2 = hero[1] else {
            snapshot = nil; convergence = []
            message = "Pick your two cards to start."
            return
        }
        let boardCards = board.compactMap { $0 }
        guard [0, 3, 4, 5].contains(boardCards.count) else {
            message = "Add at least three board cards (a full flop)."
            return
        }
        let villainRange: HandRange
        switch villainMode {
        case .hand:
            guard let v1 = villain[0], let v2 = villain[1] else {
                snapshot = nil; convergence = []
                message = "Pick the villain's two cards, or switch to a range."
                return
            }
            villainRange = HandRange(HoleCards(v1, v2))
        case .range:
            do { villainRange = try HandRange(villainRangeText) } catch let e as RangeParseError {
                rangeError = e.description; return
            } catch { rangeError = "Invalid range"; return }
        }

        let request = EquityRequest(players: [HandRange(HoleCards(h1, h2)), villainRange], board: CardSet(boardCards))
        var options = EquityCalculator.StreamOptions()
        options.trialsPerWorkerPerBatch = 2_048       // small batches: smooth convergence animation
        options.maxTrials = 3_000_000
        options.targetStandardError = 0.0005          // stop at about ±0.1% (95%)
        options.seed = UInt64.random(in: 0...UInt64.max)
        let stream: AsyncStream<EquitySnapshot>
        do { stream = try EquityCalculator.equity(request, options: options) } catch {
            message = Self.describe(error); snapshot = nil; return
        }

        convergence = []
        isRunning = true
        let myGeneration = generation
        task = Task { [weak self] in
            let clock = ContinuousClock()
            var lastUpdate = clock.now - .seconds(1)
            var latest: EquitySnapshot?
            for await snap in stream {
                latest = snap
                let now = clock.now
                if snap.isFinal || now - lastUpdate >= .milliseconds(33) {
                    lastUpdate = now
                    self?.apply(snap, generation: myGeneration)
                }
            }
            if let latest { self?.apply(latest, generation: myGeneration) }
            self?.finish(generation: myGeneration)
        }
    }

    private func apply(_ snap: EquitySnapshot, generation g: Int) {
        guard g == generation else { return }
        snapshot = snap
        let e = snap.equities[0], se = snap.standardErrors[0]
        if convergence.last?.trials != snap.samples {
            convergence.append(.init(trials: snap.samples, equity: e, low: max(0, e - 1.96 * se), high: min(1, e + 1.96 * se)))
            if convergence.count > 400 { convergence.removeFirst(convergence.count - 400) }
        }
    }

    private func finish(generation g: Int) {
        guard g == generation else { return }
        isRunning = false
        completedRuns += 1
    }

    static func describe(_ error: Error) -> String {
        switch error as? EquityError {
        case .emptyRange: "Every hand in that range uses a card that is already dealt."
        case .noValidDeal: "No valid deal: the hands and ranges overlap completely."
        case .invalidBoard: "The board must have 0, 3, 4 or 5 cards."
        default: "Could not compute equity."
        }
    }
}
