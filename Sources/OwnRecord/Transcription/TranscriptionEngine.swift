import Accelerate
@preconcurrency import AVFoundation
import Speech

enum TranscriptionError: LocalizedError {
    case notAuthorized
    case unsupportedLanguage
    case recognizerUnavailable
    case noAudio
    case noSpeech

    var errorDescription: String? {
        switch self {
        case .notAuthorized: "Speech Recognition permission is required. Enable it in System Settings › Privacy & Security."
        case .unsupportedLanguage: "This language isn't supported for transcription."
        case .recognizerUnavailable: "Speech recognition isn't available right now. Check that Siri & Dictation assets are downloaded, then try again."
        case .noAudio: "This recording has no audio to transcribe."
        case .noSpeech: "No speech was detected in this recording."
        }
    }
}

/// Transcribes a recording's audio with Apple's Speech framework (on-device when available).
///
/// Audio is split into chunks at quiet moments so long recordings stay within the
/// recognizer's limits and words are never cut in half.
enum TranscriptionEngine {
    static let sampleRate: Double = 16_000

    struct LocaleOption: Identifiable, Hashable {
        let id: String
        let name: String
    }

    static var supportedLocales: [LocaleOption] {
        SFSpeechRecognizer.supportedLocales()
            .map { LocaleOption(id: $0.identifier, name: Locale.current.localizedString(forIdentifier: $0.identifier) ?? $0.identifier) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Initial subtitle language: the Mac's language, preferring a variant that runs on-device
    /// (private and offline). E.g. English (UAE) is server-only, so English (US) is chosen.
    static func defaultLocaleIdentifier() -> String {
        let current = Locale.current
        let language = current.language.languageCode?.identifier
        let candidates = SFSpeechRecognizer.supportedLocales().filter { $0.language.languageCode?.identifier == language }
        let onDevice = candidates.filter { SFSpeechRecognizer(locale: $0)?.supportsOnDeviceRecognition == true }
        if let sameRegion = onDevice.first(where: { $0.region == current.region }) { return sameRegion.identifier }
        if let preferred = onDevice.first(where: { $0.region?.identifier == "US" }) ?? onDevice.first { return preferred.identifier }
        return bestLocaleIdentifier(for: current.identifier)
    }

    /// The supported speech locale closest to `preferred` (e.g. "en_US@rg=gbzzzz" → "en-US").
    static func bestLocaleIdentifier(for preferred: String) -> String {
        let supported = SFSpeechRecognizer.supportedLocales()
        if supported.contains(where: { $0.identifier == preferred }) { return preferred }
        let wanted = Locale(identifier: preferred)
        let language = wanted.language.languageCode?.identifier
        let region = wanted.region?.identifier
        if let match = supported.first(where: { $0.language.languageCode?.identifier == language && $0.region?.identifier == region })
            ?? supported.first(where: { $0.language.languageCode?.identifier == language })
            ?? supported.first(where: { $0.identifier.replacingOccurrences(of: "_", with: "-") == "en-US" }) {
            return match.identifier
        }
        return preferred
    }

    static func supportsOnDevice(localeIdentifier: String) -> Bool {
        SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier))?.supportsOnDeviceRecognition ?? false
    }

    /// Subtitles for a recording, from every track that's audible in its edit (muted tracks are skipped).
    static func transcript(for recording: Recording, files: RecordingFiles, localeIdentifier: String,
                           progress: @escaping @Sendable (Double) -> Void) async throws -> Transcript {
        let audio = recording.edit.audio
        let audible = recording.audioTracks.indices.filter {
            (recording.audioTracks[$0] == .microphone ? audio.microphoneVolume : audio.systemVolume) > 0
        }
        let words = try await transcribe(assetURL: files.screen,
                                         audioTrackIndices: audible.isEmpty ? Array(recording.audioTracks.indices) : audible,
                                         locale: Locale(identifier: localeIdentifier), progress: progress)
        let cues = CueBuilder.cues(from: words, joiner: CueBuilder.joiner(for: localeIdentifier))
        guard !cues.isEmpty else { throw TranscriptionError.noSpeech }
        return Transcript(localeIdentifier: localeIdentifier, createdAt: Date(), words: words, cues: cues)
    }

    /// - Parameter audioTrackIndices: Audio tracks (in track order) to mix and transcribe.
    static func transcribe(assetURL: URL, audioTrackIndices: [Int], locale: Locale,
                           progress: @escaping @Sendable (Double) -> Void) async throws -> [TranscriptWord] {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else { throw TranscriptionError.notAuthorized }
        guard let recognizer = SFSpeechRecognizer(locale: locale) else { throw TranscriptionError.unsupportedLanguage }
        guard recognizer.isAvailable else { throw TranscriptionError.recognizerUnavailable }
        recognizer.queue = OperationQueue()

        let samples = try await loadSamples(url: assetURL, trackIndices: audioTrackIndices)
        guard !samples.isEmpty else { throw TranscriptionError.noAudio }
        let chunks = chunkRanges(sampleCount: samples.count, energy: frameEnergies(samples))

        var words: [TranscriptWord] = []
        var firstError: Error?
        progress(0.02)
        for (index, range) in chunks.enumerated() {
            try Task.checkCancellation()
            let offset = Double(range.lowerBound) / sampleRate
            do {
                let chunkWords = try await recognize(samples: samples[range], recognizer: recognizer, offset: offset)
                words.append(contentsOf: chunkWords)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // A silent chunk commonly fails with "no speech detected"; keep going.
                firstError = firstError ?? error
            }
            progress(Double(index + 1) / Double(chunks.count))
        }
        if words.isEmpty, let firstError, !isNoSpeechError(firstError) {
            throw firstError
        }
        return words
    }

    // MARK: Audio loading

    static func loadSamples(url: URL, trackIndices: [Int]) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio).sorted { $0.trackID < $1.trackID }
        let selected = trackIndices.filter(tracks.indices.contains).map { tracks[$0] }
        guard !selected.isEmpty else { throw TranscriptionError.noAudio }

        let reader = try AVAssetReader(asset: asset)
        // Mixing lets subtitles cover everything audible: your voice and e.g. call participants.
        let output = AVAssetReaderAudioMixOutput(audioTracks: selected, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw TranscriptionError.noAudio }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? TranscriptionError.noAudio }

        var samples: [Float] = []
        while let buffer = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            let count = length / MemoryLayout<Float>.size
            guard count > 0 else { continue }
            let start = samples.count
            samples.append(contentsOf: repeatElement(0, count: count))
            samples.withUnsafeMutableBytes { raw in
                _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count * MemoryLayout<Float>.size,
                                               destination: raw.baseAddress!.advanced(by: start * MemoryLayout<Float>.size))
            }
        }
        if reader.status == .failed { throw reader.error ?? TranscriptionError.noAudio }
        normalize(&samples)
        return samples
    }

    /// Brings quiet recordings (e.g. a distant laptop mic) up to a healthy level. Speech
    /// recognizers, especially on-device ones, treat very quiet input as silence.
    static func normalize(_ samples: inout [Float], targetPeak: Float = 0.7, maxGain: Float = 24) {
        guard !samples.isEmpty else { return }
        var peak: Float = 0
        vDSP_maxmgv(samples, 1, &peak, vDSP_Length(samples.count))
        guard peak > 0.0005, peak < targetPeak else { return }
        var gain = min(targetPeak / peak, maxGain)
        vDSP_vsmul(samples, 1, &gain, &samples, 1, vDSP_Length(samples.count))
    }

    // MARK: Chunking

    static let frameLength = Int(sampleRate * 0.05) // 50 ms

    /// Mean-square energy per 50 ms frame.
    static func frameEnergies(_ samples: [Float]) -> [Float] {
        let frameCount = samples.count / frameLength
        var energies = [Float](repeating: 0, count: frameCount)
        samples.withUnsafeBufferPointer { pointer in
            for frame in 0..<frameCount {
                var value: Float = 0
                vDSP_measqv(pointer.baseAddress! + frame * frameLength, 1, &value, vDSP_Length(frameLength))
                energies[frame] = value
            }
        }
        return energies
    }

    /// Splits audio into chunks of `minLength...maxLength` seconds, cutting at the quietest point.
    static func chunkRanges(sampleCount: Int, energy: [Float], minLength: Double = 15, maxLength: Double = 40) -> [Range<Int>] {
        let framesPerSecond = sampleRate / Double(frameLength)
        var ranges: [Range<Int>] = []
        var start = 0
        while Double(sampleCount - start) / sampleRate > maxLength {
            let startFrame = start / frameLength
            let low = startFrame + Int(minLength * framesPerSecond)
            let high = min(energy.count - 1, startFrame + Int(maxLength * framesPerSecond))
            guard low < high else { break }
            var best = high
            var bestValue = Float.greatestFiniteMagnitude
            for frame in low...high {
                // Smooth over ~300 ms so a single quiet frame mid-word doesn't win.
                let window = max(0, frame - 3)...min(energy.count - 1, frame + 3)
                let value = energy[window].reduce(0, +) / Float(window.count)
                if value < bestValue {
                    bestValue = value
                    best = frame
                }
            }
            let cut = min(sampleCount, best * frameLength + frameLength / 2)
            guard cut > start else { break }
            ranges.append(start..<cut)
            start = cut
        }
        if start < sampleCount { ranges.append(start..<sampleCount) }
        return ranges
    }

    // MARK: Recognition

    private static func recognize(samples: ArraySlice<Float>, recognizer: SFSpeechRecognizer, offset: Double) async throws -> [TranscriptWord] {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        request.taskHint = .dictation
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
        let collector = RecognitionCollector(offset: offset)
        return try await collector.run(recognizer: recognizer, request: request) {
            let step = Int(sampleRate)
            var index = samples.startIndex
            while index < samples.endIndex {
                let end = min(index + step, samples.endIndex)
                let count = end - index
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else { break }
                buffer.frameLength = AVAudioFrameCount(count)
                samples[index..<end].withUnsafeBufferPointer { source in
                    buffer.floatChannelData![0].update(from: source.baseAddress!, count: count)
                }
                request.append(buffer)
                index = end
            }
            request.endAudio()
        }
    }

    static func isNoSpeechError(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == "kAFAssistantErrorDomain" && [203, 1110].contains(nsError.code)
    }
}

/// Collects every finalized utterance of a recognition task.
///
/// Depending on the OS version a long request may report one cumulative result or one
/// result per utterance; merging by start time handles both.
private final class RecognitionCollector: NSObject, SFSpeechRecognitionTaskDelegate, @unchecked Sendable {
    private let offset: Double
    private let lock = NSLock()
    private var words: [TranscriptWord] = []
    private var continuation: CheckedContinuation<[TranscriptWord], Error>?
    private var task: SFSpeechRecognitionTask?
    private var cancelled = false

    init(offset: Double) {
        self.offset = offset
    }

    func run(recognizer: SFSpeechRecognizer, request: SFSpeechAudioBufferRecognitionRequest,
             feed: () -> Void) async throws -> [TranscriptWord] {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                self.continuation = continuation
                lock.unlock()
                let task = recognizer.recognitionTask(with: request, delegate: self)
                lock.lock()
                self.task = task
                let cancelledEarly = cancelled
                lock.unlock()
                if cancelledEarly { task.cancel() }
                feed()
            }
        } onCancel: {
            lock.lock()
            cancelled = true
            let task = self.task
            lock.unlock()
            task?.cancel()
        }
    }

    func speechRecognitionTask(_ task: SFSpeechRecognitionTask, didFinishRecognition result: SFSpeechRecognitionResult) {
        let segments = result.bestTranscription.segments
        guard let first = segments.first else { return }
        let newStart = offset + first.timestamp
        let newWords = segments.map {
            TranscriptWord(text: $0.substring, start: offset + $0.timestamp, end: offset + $0.timestamp + $0.duration)
        }
        lock.lock()
        words.removeAll { $0.start >= newStart - 0.01 }
        words.append(contentsOf: newWords)
        lock.unlock()
    }

    func speechRecognitionTask(_ task: SFSpeechRecognitionTask, didFinishSuccessfully successfully: Bool) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        let collected = words
        lock.unlock()
        if successfully || !collected.isEmpty {
            continuation?.resume(returning: collected)
        } else if let error = task.error, TranscriptionEngine.isNoSpeechError(error) {
            continuation?.resume(returning: [])
        } else {
            continuation?.resume(throwing: task.error ?? TranscriptionError.recognizerUnavailable)
        }
    }

    func speechRecognitionTaskWasCancelled(_ task: SFSpeechRecognitionTask) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(throwing: CancellationError())
    }
}
