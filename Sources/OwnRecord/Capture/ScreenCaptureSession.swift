@preconcurrency import AVFoundation
@preconcurrency import ScreenCaptureKit

/// Streams a display, window or area with ScreenCaptureKit into a `MovieWriter`.
final class ScreenCaptureSession: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    /// Called on an arbitrary queue when the system stops the stream (e.g. the user
    /// clicked "Stop Sharing" in the menu bar or the captured window closed).
    var onUnexpectedStop: ((Error) -> Void)?

    private let queue: DispatchQueue
    private let clock: RecordingClock
    private let writer: MovieWriter
    private var stream: SCStream?
    /// Most recent complete frame. ScreenCaptureKit only delivers frames when the screen
    /// changes, so this is re-appended at the start and after resuming a pause.
    private var latestFrame: CVPixelBuffer?

    init(queue: DispatchQueue, clock: RecordingClock, writer: MovieWriter) {
        self.queue = queue
        self.clock = clock
        self.writer = writer
    }

    func start(filter: SCContentFilter, configuration: SCStreamConfiguration) async throws {
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if configuration.capturesAudio {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        }
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async {
        guard let stream else { return }
        self.stream = nil
        try? await stream.stopCapture()
    }

    /// Appends the latest frame at `time`. Must be called on `queue`.
    func writeHeldFrame(at time: CMTime) {
        if let latestFrame {
            writer.appendVideo(latestFrame, at: time)
        }
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }
        switch type {
        case .screen:
            guard Self.isCompleteFrame(sampleBuffer), let pixelBuffer = sampleBuffer.imageBuffer else { return }
            latestFrame = pixelBuffer
            if let time = clock.outputTime(for: sampleBuffer.presentationTimeStamp) {
                writer.appendVideo(pixelBuffer, at: time)
            }
        case .audio:
            if let time = clock.outputTime(for: sampleBuffer.presentationTimeStamp) {
                writer.appendAudio(sampleBuffer, kind: .system, at: time)
            }
        default:
            break
        }
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onUnexpectedStop?(error)
    }

    private static func isCompleteFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: rawStatus) else { return false }
        return status == .complete
    }
}
