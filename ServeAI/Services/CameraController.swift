import AVFoundation
import Foundation

final class CameraController: NSObject, ObservableObject {
    @Published private(set) var isConfigured = false
    @Published private(set) var isRecording = false
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var recordedURL: URL?
    @Published var error: ServeAIError?

    let session = AVCaptureSession()
    private let movieOutput = AVCaptureMovieFileOutput()
    private var videoInput: AVCaptureDeviceInput?
    private var timer: Timer?
    private var startedAt: Date?

    func configure() async {
        guard !isConfigured else { return }
        let videoAccess = await AVCaptureDevice.requestAccess(for: .video)
        guard videoAccess else {
            await MainActor.run { self.error = .cameraPermissionDenied }
            return
        }
        _ = await AVCaptureDevice.requestAccess(for: .audio)
        do {
            try configureSession(position: .back)
            session.startRunning()
            await MainActor.run { self.isConfigured = true }
        } catch let known as ServeAIError {
            await MainActor.run { self.error = known }
        } catch {
            await MainActor.run { self.error = .recordingFailed(error.localizedDescription) }
        }
    }

    private func configureSession(position: AVCaptureDevice.Position) throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .high
        for input in session.inputs { session.removeInput(input) }

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position) else {
            throw ServeAIError.recordingFailed("No camera is available on this device")
        }
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw ServeAIError.recordingFailed("The camera input could not be added") }
        session.addInput(input)
        videoInput = input

        if let audio = AVCaptureDevice.default(for: .audio), let audioInput = try? AVCaptureDeviceInput(device: audio), session.canAddInput(audioInput) {
            session.addInput(audioInput)
        }
        if !session.outputs.contains(movieOutput), session.canAddOutput(movieOutput) { session.addOutput(movieOutput) }
        if let connection = movieOutput.connection(with: .video), connection.isVideoStabilizationSupported { connection.preferredVideoStabilizationMode = .standard }
    }

    func toggleRecording() {
        isRecording ? stopRecording() : startRecording()
    }

    func startRecording() {
        guard isConfigured, !movieOutput.isRecording else { return }
        let url = FileManager.default.temporaryDirectory.appending(path: "serve-\(UUID().uuidString).mov")
        recordedURL = nil
        duration = 0
        startedAt = .now
        isRecording = true
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self, let startedAt = self.startedAt else { return }
            self.duration = Date().timeIntervalSince(startedAt)
            if self.duration >= 45 { self.stopRecording() }
        }
        movieOutput.startRecording(to: url, recordingDelegate: self)
    }

    func stopRecording() {
        guard movieOutput.isRecording else { return }
        movieOutput.stopRecording()
        timer?.invalidate()
        timer = nil
        isRecording = false
    }

    func switchCamera() {
        guard !isRecording, let position = videoInput?.device.position else { return }
        do { try configureSession(position: position == .back ? .front : .back) }
        catch { self.error = .recordingFailed(error.localizedDescription) }
    }

    func stopSession() {
        if isRecording { stopRecording() }
        if session.isRunning { session.stopRunning() }
        timer?.invalidate()
    }
}

extension CameraController: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        DispatchQueue.main.async {
            self.isRecording = false
            self.timer?.invalidate()
            if let error { self.error = .recordingFailed(error.localizedDescription) }
            else { self.recordedURL = outputFileURL }
        }
    }
}
