@preconcurrency import AVFoundation

/// Runs the camera for the live bubble preview and records it to its own movie file.
///
/// The camera is recorded separately (not burned into the screen recording) so its shape,
/// size and position can be changed after recording.
final class CameraCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let session = AVCaptureSession()

    private let output = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "com.ownrecord.camera.session")
    private let sampleQueue = DispatchQueue(label: "com.ownrecord.camera.samples", qos: .userInitiated)
    private let stateLock = NSLock()
    private var _deviceID: String?

    // Recording state, confined to `sampleQueue`.
    private var recordingURL: URL?
    private var clock: RecordingClock?
    private var writer: MovieWriter?
    private var writerFailed = false
    private var frameSize: (width: Int, height: Int)?

    override init() {
        super.init()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: sampleQueue)
        session.beginConfiguration()
        if session.canAddOutput(output) { session.addOutput(output) }
        session.commitConfiguration()
    }

    var deviceID: String? {
        stateLock.lock(); defer { stateLock.unlock() }
        return _deviceID
    }

    /// Switches to the given camera (or none) and starts/stops the session accordingly.
    func use(deviceID: String?) {
        stateLock.lock()
        let changed = _deviceID != deviceID
        _deviceID = deviceID
        stateLock.unlock()

        sessionQueue.async { [session] in
            if changed {
                session.beginConfiguration()
                session.inputs.forEach { session.removeInput($0) }
                if let deviceID, let device = AVCaptureDevice(uniqueID: deviceID),
                   let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) {
                    session.addInput(input)
                    for preset in [AVCaptureSession.Preset.hd1920x1080, .hd1280x720, .high] where session.canSetSessionPreset(preset) {
                        session.sessionPreset = preset
                        break
                    }
                }
                session.commitConfiguration()
            }
            if deviceID != nil, !session.inputs.isEmpty {
                if !session.isRunning { session.startRunning() }
            } else if session.isRunning {
                session.stopRunning()
            }
        }
    }

    func stop() {
        use(deviceID: nil)
    }

    var isActive: Bool {
        deviceID != nil
    }

    /// Prepares the camera file. The writer is created now (before the countdown) so the
    /// camera track has frames from the very first moment of the recording.
    func beginRecording(to url: URL, clock: RecordingClock) {
        sampleQueue.sync {
            recordingURL = url
            self.clock = clock
            writer = nil
            writerFailed = false
            if let frameSize { makeWriter(url: url, width: frameSize.width, height: frameSize.height) }
        }
    }

    private func makeWriter(url: URL, width: Int, height: Int) {
        do {
            writer = try MovieWriter(url: url, video: .camera(width: width, height: height), audioTracks: [])
        } catch {
            writerFailed = true
        }
    }

    /// Finalizes the camera file. Returns true if any frames were recorded.
    func finishRecording(at endTime: CMTime) async -> Bool {
        let writer: MovieWriter? = sampleQueue.sync {
            let current = self.writer
            current?.prepareToFinish(at: endTime)
            self.writer = nil
            self.clock = nil
            self.recordingURL = nil
            return current
        }
        guard let writer else { return false }
        return (try? await writer.finishWriting()) ?? false
    }

    func cancelRecording() {
        sampleQueue.sync {
            writer?.cancel()
            writer = nil
            clock = nil
            recordingURL = nil
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = sampleBuffer.imageBuffer else { return }
        let width = CVPixelBufferGetWidth(pixelBuffer), height = CVPixelBufferGetHeight(pixelBuffer)
        if frameSize?.width != width || frameSize?.height != height { frameSize = (width, height) }

        guard let clock, let url = recordingURL, let start = clock.startTime else { return }
        let hostTime = CMSyncConvertTime(sampleBuffer.presentationTimeStamp,
                                         from: session.synchronizationClock ?? CMClockGetHostTimeClock(),
                                         to: CMClockGetHostTimeClock())
        guard let time = clock.outputTime(for: hostTime) else { return }
        if writer == nil, !writerFailed {
            makeWriter(url: url, width: width, height: height)
        }
        // Same session start as the screen writer keeps both files aligned.
        writer?.start(at: start)
        writer?.appendVideo(pixelBuffer, at: time)
    }
}
