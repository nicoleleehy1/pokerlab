import SwiftUI
import PokerCore
import CardRecognitionCore

/// Main-actor state for the scan screen: debounces raw detections into a stable hand and board.
@MainActor @Observable
final class CardScanModel {
    enum Status: Equatable {
        case idle, starting, scanning
        case failed(CardCaptureController.SetupError)
    }

    private(set) var status: Status = .idle
    private(set) var boxes: [CardDetection] = []
    private(set) var imageAspect: Double = 9.0 / 16
    private(set) var hero: [Card] = []
    private(set) var board: [Card] = []
    /// Bumped whenever the confirmed cards change, for haptics.
    private(set) var changeCount = 0

    let controller = CardCaptureController()
    private var debouncer = FrameDebouncer()

    var confirmed: Set<Card> { debouncer.confirmed }
    var canUse: Bool { hero.count == 2 }

    func start() async {
        guard status == .idle || status == .scanning else { return }
        status = .starting
        controller.onDetections = { [weak self] detections, aspect in
            Task { @MainActor in self?.ingest(detections, aspect: aspect) }
        }
        do {
            try await controller.start()
            status = .scanning
        } catch {
            status = .failed(error)
        }
    }

    func stop() {
        controller.stop()
        if status == .scanning { status = .idle }
    }

    func reset() {
        debouncer.reset()
        hero = []; board = []; boxes = []
    }

    func ingest(_ detections: [CardDetection], aspect: Double) {
        imageAspect = aspect
        let before = debouncer.confirmed
        debouncer.ingest(detections)
        boxes = detections
        let split = TableLayout.split(detections, confirmed: debouncer.confirmed)
        // Keep the last known placement for confirmed cards that were missed in this frame.
        hero = split.hero.count == 2 || debouncer.confirmed != before ? split.hero : hero.filter(debouncer.confirmed.contains)
        if split.board.count >= board.count || debouncer.confirmed != before { board = split.board }
        board = board.filter(debouncer.confirmed.contains)
        if debouncer.confirmed != before { changeCount += 1 }
    }
}
