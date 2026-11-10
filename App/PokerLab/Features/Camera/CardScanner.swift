@preconcurrency import AVFoundation
@preconcurrency import Vision
import CoreML
import PokerCore
import CardRecognitionCore

/// Owns the AVCaptureSession and runs the card detector on every frame it can keep up with.
///
/// Threading: every session call happens on `sessionQueue`; frames arrive on `videoQueue`,
/// where Vision runs synchronously. Because the output discards late frames, a slow model
/// simply analyses fewer frames instead of queueing them. Results leave this class as
/// Sendable `[CardDetection]` values through `onDetections`.
final class CardCaptureController: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    enum SetupError: Error, Equatable {
        case cameraUnavailable
        case permissionDenied
        case modelMissing
        case modelFailed(String)
    }

    /// Name of the compiled Create ML model in the app bundle (see README, "Training the card detector").
    static let modelName = "CardDetector"

    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "PokerLab.capture.session")
    private let videoQueue = DispatchQueue(label: "PokerLab.capture.video", qos: .userInitiated)
    private let output = AVCaptureVideoDataOutput()
    private var request: VNCoreMLRequest?
    private var configured = false

    /// Called on the video queue with each analysed frame's detections.
    var onDetections: (@Sendable ([CardDetection], _ imageAspect: Double) -> Void)?

    /// Loads the bundled model. Returns `.modelMissing` when none has been added yet.
    static func loadRequest() throws(SetupError) -> VNCoreMLRequest {
        guard let url = Bundle.main.url(forResource: modelName, withExtension: "mlmodelc") else { throw .modelMissing }
        do {
            let config = MLModelConfiguration()
            config.computeUnits = .all
            let model = try VNCoreMLModel(for: MLModel(contentsOf: url, configuration: config))
            let request = VNCoreMLRequest(model: model)
            // Create ML object detectors are trained on the whole image, squashed to the input size.
            request.imageCropAndScaleOption = .scaleFill
            return request
        } catch {
            throw .modelFailed(error.localizedDescription)
        }
    }

    static func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: .video)
        default: false
        }
    }

    /// Configures (once) and starts the session.
    func start() async throws(SetupError) {
        guard await Self.requestPermission() else { throw .permissionDenied }
        let request = try Self.loadRequest()
        let result: Result<Void, SetupError> = await withCheckedContinuation { cont in
            sessionQueue.async { [self] in
                if !configured {
                    if let error = configure() { cont.resume(returning: .failure(error)); return }
                    self.request = request
                    configured = true
                }
                if !session.isRunning { session.startRunning() }
                cont.resume(returning: .success(()))
            }
        }
        try result.get()
    }

    func stop() {
        sessionQueue.async { [self] in
            if session.isRunning { session.stopRunning() }
        }
    }

    private func configure() -> SetupError? {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device) else { return .cameraUnavailable }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        // 1080p is plenty for cards a metre away and keeps the model input resize cheap.
        session.sessionPreset = session.canSetSessionPreset(.hd1920x1080) ? .hd1920x1080 : .high
        guard session.canAddInput(input) else { return .cameraUnavailable }
        session.addInput(input)
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.setSampleBufferDelegate(self, queue: videoQueue)
        guard session.canAddOutput(output) else { return .cameraUnavailable }
        session.addOutput(output)
        // Deliver portrait buffers so Vision coordinates match what the user sees.
        if let connection = output.connection(with: .video), connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }
        if (try? device.lockForConfiguration()) != nil {
            if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
            device.unlockForConfiguration()
        }
        return nil
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let request, let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let handler = VNImageRequestHandler(cvPixelBuffer: pixels, orientation: .up)
        do { try handler.perform([request]) } catch { return }
        let observations = (request.results as? [VNRecognizedObjectObservation]) ?? []
        let detections = observations.compactMap { obs -> CardDetection? in
            guard let top = obs.labels.first, let card = CardLabel.card(from: top.identifier) else { return nil }
            let b = obs.boundingBox
            return CardDetection(card: card, confidence: top.confidence,
                                 x: b.origin.x, y: b.origin.y, width: b.width, height: b.height)
        }
        let aspect = Double(CVPixelBufferGetWidth(pixels)) / Double(max(1, CVPixelBufferGetHeight(pixels)))
        onDetections?(detections, aspect)
    }
}
