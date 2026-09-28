@preconcurrency import AVFoundation

/// Captures the selected microphone. Provides a live level for meters and, while
/// recording, writes into the screen movie as its own audio track.
final class MicrophoneCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let session = AVCaptureSession()
    private let output = AVCaptureAudioDataOutput()
    private let sessionQueue = DispatchQueue(label: "com.ownrecord.mic.session")
    /// Shared with the screen capture so all writes to the screen movie are serialized.
    private let sampleQueue: DispatchQueue
    private let lock = NSLock()
    private var _deviceID: String?
    private var _level: Float = 0

    // Confined to `sampleQueue`.
    private var writer: MovieWriter?
    private var clock: RecordingClock?

    init(sampleQueue: DispatchQueue) {
        self.sampleQueue = sampleQueue
        super.init()
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        output.setSampleBufferDelegate(self, queue: sampleQueue)
        session.beginConfiguration()
        if session.canAddOutput(output) { session.addOutput(output) }
        session.commitConfiguration()
    }

    var deviceID: String? {
        lock.lock(); defer { lock.unlock() }
        return _deviceID
    }

    /// Normalized input level, 0...1.
    var level: Float {
        lock.lock(); defer { lock.unlock() }
        return _level
    }

    func use(deviceID: String?) {
        lock.lock()
        let changed = _deviceID != deviceID
        _deviceID = deviceID
        if deviceID == nil { _level = 0 }
        lock.unlock()

        sessionQueue.async { [session] in
            if changed {
                session.beginConfiguration()
                session.inputs.forEach { session.removeInput($0) }
                if let deviceID, let device = AVCaptureDevice(uniqueID: deviceID),
                   let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) {
                    session.addInput(input)
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

    func attach(writer: MovieWriter, clock: RecordingClock) {
        sampleQueue.sync {
            self.writer = writer
            self.clock = clock
        }
    }

    /// Must be called on the shared sample queue (or synchronously dispatched onto it).
    func detachOnQueue() {
        writer = nil
        clock = nil
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if let power = connection.audioChannels.first?.averagePowerLevel {
            // -50 dB (quiet room) … 0 dB (clipping) → 0…1
            let normalized = max(0, min(1, (power + 50) / 50))
            lock.lock()
            _level = normalized
            lock.unlock()
        }
        guard let writer, let clock else { return }
        let hostTime = CMSyncConvertTime(sampleBuffer.presentationTimeStamp,
                                         from: session.synchronizationClock ?? CMClockGetHostTimeClock(),
                                         to: CMClockGetHostTimeClock())
        if let time = clock.outputTime(for: hostTime) {
            writer.appendAudio(sampleBuffer, kind: .microphone, at: time)
        }
    }
}
