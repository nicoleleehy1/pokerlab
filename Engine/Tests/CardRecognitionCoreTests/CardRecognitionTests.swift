import Testing
import PokerCore
@testable import CardRecognitionCore

@Suite("Card labels")
struct CardLabelTests {
    @Test("Short labels in any case", arguments: [
        ("As", "As"), ("AS", "As"), ("as", "As"), ("Th", "Th"), ("10h", "Th"), ("10H", "Th"), ("2c", "2c"), (" Kd ", "Kd"),
    ])
    func shortLabels(label: String, expected: String) {
        #expect(CardLabel.card(from: label) == Card(expected))
    }

    @Test("Word labels", arguments: [
        ("ace_of_spades", "As"), ("10_hearts", "Th"), ("queen of diamonds", "Qd"), ("two-clubs", "2c"), ("K_spades", "Ks"),
    ])
    func wordLabels(label: String, expected: String) {
        #expect(CardLabel.card(from: label) == Card(expected))
    }

    @Test("Rejects junk", arguments: ["", "joker", "1s", "Ax", "ace_of_cups", "card"])
    func junk(label: String) {
        #expect(CardLabel.card(from: label) == nil)
    }

    @Test("Every card's own description maps back to it")
    func roundTrip() {
        for c in Card.all { #expect(CardLabel.card(from: c.description) == c) }
    }
}

@Suite("Frame debouncer")
struct DebouncerTests {
    let ace = Card("As")!, king = Card("Kd")!

    func frame(_ cards: Card..., confidence: Float = 0.9) -> [CardDetection] {
        cards.map { CardDetection(card: $0, confidence: confidence) }
    }

    @Test("A card is confirmed only after enough hits")
    func confirmAfterHits() {
        var d = FrameDebouncer(window: 8, minimumHits: 5, releaseHits: 2)
        for _ in 0..<4 { #expect(d.ingest(frame(ace)).isEmpty) }
        #expect(d.ingest(frame(ace)) == [ace])
    }

    @Test("Low-confidence detections are ignored")
    func lowConfidence() {
        var d = FrameDebouncer(minimumConfidence: 0.6)
        for _ in 0..<10 { d.ingest(frame(ace, confidence: 0.4)) }
        #expect(d.confirmed.isEmpty)
    }

    @Test("Hysteresis: a confirmed card survives brief dropouts, then is released")
    func hysteresis() {
        var d = FrameDebouncer(window: 8, minimumHits: 5, releaseHits: 2)
        for _ in 0..<8 { d.ingest(frame(ace)) }
        // Three missed frames: still 5 hits in the window.
        for _ in 0..<3 { d.ingest([]) }
        #expect(d.confirmed == [ace])
        // Six missed frames: 2 hits left, still at the release threshold.
        for _ in 0..<3 { d.ingest([]) }
        #expect(d.confirmed == [ace])
        d.ingest([])
        #expect(d.confirmed.isEmpty)
    }

    @Test("A one-frame misread never becomes confirmed")
    func flicker() {
        var d = FrameDebouncer()
        for i in 0..<20 { d.ingest(i % 7 == 0 ? frame(king) : frame(ace)) }
        #expect(d.confirmed == [ace])
    }

    @Test("Duplicate boxes for one card count once per frame")
    func duplicates() {
        var d = FrameDebouncer(window: 8, minimumHits: 5, releaseHits: 2)
        for _ in 0..<3 { d.ingest(frame(ace, ace, ace)) }
        #expect(d.confirmed.isEmpty)
    }

    @Test("Reset clears everything")
    func reset() {
        var d = FrameDebouncer()
        for _ in 0..<8 { d.ingest(frame(ace)) }
        d.reset()
        #expect(d.confirmed.isEmpty)
        #expect(d.ingest(frame(ace)).isEmpty)
    }
}

@Suite("Table layout")
struct TableLayoutTests {
    func det(_ s: String, x: Double, y: Double, confidence: Float = 0.9) -> CardDetection {
        CardDetection(card: Card(s)!, confidence: confidence, x: x, y: y, width: 0.1, height: 0.1)
    }

    @Test("Lower cards are the hero's, upper cards the board, both sorted left to right")
    func split() {
        let dets = [det("Ah", x: 0.5, y: 0.05), det("Kh", x: 0.3, y: 0.05),
                    det("Qc", x: 0.6, y: 0.5), det("2d", x: 0.2, y: 0.5), det("7s", x: 0.4, y: 0.5)]
        let (hero, board) = TableLayout.split(dets, confirmed: Set(dets.map(\.card)))
        #expect(hero == [Card("Kh")!, Card("Ah")!])
        #expect(board == [Card("2d")!, Card("7s")!, Card("Qc")!])
    }

    @Test("Unconfirmed detections are left out; the best box per card wins")
    func filtering() {
        let dets = [det("Ah", x: 0.5, y: 0.05), det("Kh", x: 0.3, y: 0.05),
                    det("Ah", x: 0.9, y: 0.6, confidence: 0.5)]
        let (hero, board) = TableLayout.split(dets, confirmed: [Card("Ah")!])
        #expect(hero == [Card("Ah")!])
        #expect(board.isEmpty)
    }

    @Test("At most two hero cards and five board cards")
    func caps() {
        let low = ["2c", "3c", "4c"].enumerated().map { det($1, x: Double($0) / 10, y: 0.0) }
        let high = ["5d", "6d", "7d", "8d", "9d", "Td"].enumerated().map { det($1, x: Double($0) / 10, y: 0.6) }
        let all = low + high
        let (hero, board) = TableLayout.split(all, confirmed: Set(all.map(\.card)))
        #expect(hero.count == 2)
        #expect(board.count == 5)
    }
}

@Suite("Overlay geometry")
struct OverlayGeometryTests {
    typealias R = OverlayGeometry.Rect

    @Test("Same aspect: plain scale with the y axis flipped")
    func sameAspect() {
        let r = OverlayGeometry.viewRect(for: R(x: 0.25, y: 0.0, width: 0.5, height: 0.25),
                                         imageAspect: 0.5, viewWidth: 100, viewHeight: 200)
        #expect(r == R(x: 25, y: 150, width: 50, height: 50))
    }

    @Test("Wider image than view: cropped left and right")
    func widerImage() {
        // 1:1 image in a 100x200 view is drawn 200x200, shifted 50 pt left.
        let r = OverlayGeometry.viewRect(for: R(x: 0.5, y: 0.5, width: 0.25, height: 0.25),
                                         imageAspect: 1, viewWidth: 100, viewHeight: 200)
        #expect(r == R(x: 50, y: 50, width: 50, height: 50))
    }

    @Test("Taller image than view: cropped top and bottom")
    func tallerImage() {
        // 9:16 image in a 200x200 view is drawn 200x355.6, shifted up by 77.8.
        let r = OverlayGeometry.viewRect(for: R(x: 0, y: 0, width: 1, height: 1),
                                         imageAspect: 9.0 / 16, viewWidth: 200, viewHeight: 200)
        #expect(abs(r.y - (200 - 200 * 16 / 9) / 2) < 1e-9)
        #expect(abs(r.height - 200 * 16 / 9) < 1e-9)
    }
}
