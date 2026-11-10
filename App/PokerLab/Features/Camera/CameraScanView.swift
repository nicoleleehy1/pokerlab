import SwiftUI
import AVFoundation
import PokerCore
import CardRecognitionCore

/// Live camera view that reads the cards on a table with a Create ML object detector and
/// sends them to the Equity Lab. The lower third of the frame is treated as the hero's hand.
struct CameraScanView: View {
    @Environment(AppRouter.self) private var router
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var model = CardScanModel()

    var body: some View {
        Group {
            switch model.status {
            case .failed(let error): failure(error)
            default: scanner
            }
        }
        .navigationTitle("Scan a Table")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.start() }
        .onDisappear { model.stop() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await model.start() } } else { model.stop() }
        }
        .sensoryFeedback(.selection, trigger: model.changeCount)
    }

    private var scanner: some View {
        ZStack(alignment: .bottom) {
            GeometryReader { geo in
                ZStack {
                    CameraPreview(session: model.controller.session)
                    // Hero zone guide: the lower third of the frame.
                    VStack {
                        Spacer()
                        RoundedRectangle(cornerRadius: 16)
                            .strokeBorder(Theme.hero.opacity(0.8), style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                            .frame(height: geo.size.height / 3 - 16)
                            .padding(8)
                            .overlay(alignment: .top) {
                                Text("Your cards here").font(.caption.weight(.semibold))
                                    .padding(.horizontal, 8).padding(.vertical, 3)
                                    .background(.ultraThinMaterial, in: Capsule()).padding(.top, 14)
                            }
                    }
                    .accessibilityHidden(true)
                    ForEach(Array(model.boxes.enumerated()), id: \.offset) { _, d in
                        box(d, in: geo.size)
                    }
                }
            }
            .ignoresSafeArea(edges: .bottom)
            resultTray
        }
    }

    private func box(_ d: CardDetection, in size: CGSize) -> some View {
        let r = OverlayGeometry.viewRect(for: .init(x: d.x, y: d.y, width: d.width, height: d.height),
                                         imageAspect: model.imageAspect, viewWidth: size.width, viewHeight: size.height)
        let confirmed = model.confirmed.contains(d.card)
        return RoundedRectangle(cornerRadius: 6)
            .stroke(confirmed ? Theme.hero : .white.opacity(0.7), lineWidth: confirmed ? 3 : 1.5)
            .overlay(alignment: .topLeading) {
                Text(d.card.description).font(.caption2.weight(.bold).monospaced())
                    .padding(.horizontal, 4).background(confirmed ? Theme.hero : .black.opacity(0.5))
                    .foregroundStyle(.white).offset(y: -16)
            }
            .frame(width: r.width, height: r.height)
            .position(x: r.x + r.width / 2, y: r.y + r.height / 2)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: r.x)
            .accessibilityHidden(true)
    }

    private var resultTray: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 16) {
                cardRow(title: "You", cards: model.hero, slots: 2)
                cardRow(title: "Board", cards: model.board, slots: 5)
            }
            HStack {
                Button("Reset", systemImage: "arrow.counterclockwise") { model.reset() }
                    .buttonStyle(.bordered)
                Spacer()
                Button {
                    router.sendToLab(LabSpot(hero: model.hero, board: model.board))
                } label: {
                    Label("Calculate equity", systemImage: "flask").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canUse)
            }
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
        .padding()
    }

    private func cardRow(title: String, cards: [Card], slots: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            HStack(spacing: 3) {
                ForEach(0..<slots, id: \.self) { i in
                    if i < cards.count {
                        Text(cards[i].description).font(.footnote.weight(.bold).monospaced())
                            .foregroundStyle(cards[i].suit == .hearts || cards[i].suit == .diamonds ? Color.red : Color.primary)
                            .frame(width: 30, height: 40)
                            .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 5))
                            .transition(.scale.combined(with: .opacity))
                    } else {
                        RoundedRectangle(cornerRadius: 5).strokeBorder(.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3]))
                            .frame(width: 30, height: 40)
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(cards.isEmpty ? "No cards detected" : cards.map(\.spokenName).joined(separator: ", "))
    }

    @ViewBuilder
    private func failure(_ error: CardCaptureController.SetupError) -> some View {
        switch error {
        case .permissionDenied:
            ContentUnavailableView {
                Label("Camera access is off", systemImage: "camera.badge.ellipsis")
            } description: {
                Text("Allow camera access in Settings so PokerLab can read the cards on the table.")
            } actions: {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
            }
        case .cameraUnavailable:
            ContentUnavailableView("No camera available", systemImage: "camera.metering.unknown",
                                   description: Text("Card scanning needs a device with a rear camera. The simulator has none."))
        case .modelMissing:
            ContentUnavailableView {
                Label("Card detector not installed", systemImage: "cpu")
            } description: {
                Text("This build has no CardDetector model yet. Train one in Create ML from photos of real cards and add CardDetector.mlmodel to the app target. The README explains how.")
            }
        case .modelFailed(let message):
            ContentUnavailableView("Couldn't load the card detector", systemImage: "exclamationmark.triangle",
                                   description: Text(message))
        }
    }
}

/// Hosts an AVCaptureVideoPreviewLayer.
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        view.backgroundColor = .black
        view.isAccessibilityElement = true
        view.accessibilityLabel = "Camera preview"
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}
}
