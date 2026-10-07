import CoreMedia
import Foundation
@testable import OwnRecord
import Testing

private func seconds(_ value: Double) -> CMTime { CMTime(seconds: value, preferredTimescale: 600) }

@Suite struct RecordingClockTests {
    @Test func dropsSamplesBeforeStartAndWhilePaused() {
        let clock = RecordingClock()
        #expect(clock.outputTime(for: seconds(5)) == nil)
        clock.begin(at: seconds(10))
        #expect(clock.outputTime(for: seconds(9)) == nil)
        #expect(clock.outputTime(for: seconds(11))?.seconds == 11)

        clock.pause(at: seconds(12))
        #expect(clock.isPaused)
        #expect(clock.outputTime(for: seconds(13)) == nil)
        clock.resume(at: seconds(15))
        #expect(!clock.isPaused)
        // 3 seconds of pause are removed from later samples.
        #expect(clock.outputTime(for: seconds(16))?.seconds == 13)
        // A late-delivered sample captured before the pause keeps its time.
        #expect(clock.outputTime(for: seconds(11.5))?.seconds == 11.5)
    }

    @Test func endTimeAndElapsedArePauseAware() {
        let clock = RecordingClock()
        clock.begin(at: seconds(10))
        clock.pause(at: seconds(12))
        clock.resume(at: seconds(15))
        #expect(clock.endTime(at: seconds(20))?.seconds == 17)
        #expect(abs(clock.elapsed(at: seconds(20)) - 7) < 0.001)

        clock.pause(at: seconds(25))
        // Stopping while paused ends at the pause point.
        #expect(clock.endTime(at: seconds(30))?.seconds == 22)
    }

    @Test func endingDropsEverything() {
        let clock = RecordingClock()
        clock.begin(at: seconds(1))
        clock.end()
        #expect(clock.outputTime(for: seconds(2)) == nil)
    }
}

@Suite struct LayoutEngineTests {
    @Test func canvasContainsSourceWithRequestedAspect() {
        let source = CGSize(width: 1440, height: 900)
        #expect(LayoutEngine.canvasSize(source: source, aspect: .original) == source)
        #expect(LayoutEngine.canvasSize(source: source, aspect: .landscape) == CGSize(width: 1600, height: 900))
        #expect(LayoutEngine.canvasSize(source: source, aspect: .square) == CGSize(width: 1440, height: 1440))

        let portrait = LayoutEngine.canvasSize(source: CGSize(width: 1920, height: 1080), aspect: .portrait)
        #expect(portrait.width == 1920)
        #expect(abs(portrait.width / portrait.height - 9.0 / 16.0) < 0.002)
        #expect(Int(portrait.width) % 2 == 0 && Int(portrait.height) % 2 == 0)
    }

    @Test func canvasIsCappedAt4KForHugeCanvases() {
        let canvas = LayoutEngine.canvasSize(source: CGSize(width: 3024, height: 1964), aspect: .portrait)
        #expect(max(canvas.width, canvas.height) <= 3840)
    }

    @Test func screenFitsInsidePadding() {
        var edit = EditSettings()
        edit.layout.padding = 0.1
        let layout = LayoutEngine.layout(canvas: CGSize(width: 1920, height: 1080), source: CGSize(width: 1920, height: 1080),
                                         edit: edit, hasCamera: false)
        #expect(abs(layout.screenRect.minY - 108) < 0.5)
        #expect(abs(layout.screenRect.midX - 960) < 0.5)
        #expect(layout.cameraRect == nil)
    }

    @Test func cameraCornersAndClamping() {
        let canvas = CGSize(width: 1920, height: 1080)
        var style = CameraOverlayStyle()
        style.size = 0.25
        style.margin = 0.05
        style.position = .bottomRight
        let rect = LayoutEngine.cameraRect(style: style, canvas: canvas)
        #expect(rect.width == 270 && rect.height == 270)
        #expect(abs(rect.maxX - (1920 - 54)) < 0.001)
        #expect(abs(rect.maxY - (1080 - 54)) < 0.001)

        style.position = .custom
        style.customX = 1.2
        style.customY = -0.3
        let clamped = LayoutEngine.cameraRect(style: style, canvas: canvas)
        #expect(clamped.maxX <= canvas.width && clamped.minY >= 0)

        style.shape = .roundedRectangle
        let wide = LayoutEngine.cameraRect(style: style, canvas: canvas)
        #expect(abs(wide.width / wide.height - 16.0 / 9.0) < 0.001)
    }

    @Test func subtitlesAvoidCameraInTheSameBand() {
        var edit = EditSettings()
        let canvas = CGSize(width: 1920, height: 1080)
        let without = LayoutEngine.layout(canvas: canvas, source: canvas, edit: edit, hasCamera: false)
        edit.camera.position = .bottomRight
        let with = LayoutEngine.layout(canvas: canvas, source: canvas, edit: edit, hasCamera: true)
        let camera = try! #require(with.cameraRect)
        #expect(with.subtitleMaxWidth < without.subtitleMaxWidth)
        #expect(canvas.width / 2 + with.subtitleMaxWidth / 2 <= camera.minX)
    }

    @Test func snapsToNearbyCorner() {
        let canvas = CGSize(width: 1920, height: 1080)
        var style = CameraOverlayStyle()
        style.position = .topLeft
        let rect = LayoutEngine.cameraRect(style: style, canvas: canvas)
        let nearby = CGPoint(x: (rect.midX + 20) / canvas.width, y: (rect.midY + 10) / canvas.height)
        #expect(LayoutEngine.snappedCorner(for: nearby, style: style, canvas: canvas) == .topLeft)
        #expect(LayoutEngine.snappedCorner(for: CGPoint(x: 0.5, y: 0.5), style: style, canvas: canvas) == nil)
    }
}

@Suite struct SubtitleTests {
    private func words(_ text: String, start: Double = 0, step: Double = 0.4) -> [TranscriptWord] {
        text.split(separator: " ").enumerated().map { index, word in
            TranscriptWord(text: String(word), start: start + Double(index) * step, end: start + Double(index) * step + 0.3)
        }
    }

    @Test func groupsWordsIntoReadableCues() {
        let input = words("Welcome to the demo. Today we will record the screen and add subtitles automatically for everyone watching.")
        let cues = CueBuilder.cues(from: input)
        #expect(cues.count >= 2)
        #expect(cues[0].text == "Welcome to the demo.")
        #expect(cues.allSatisfy { $0.text.count <= 64 })
        for (current, next) in zip(cues, cues.dropFirst()) {
            #expect(current.end <= next.start)
        }
    }

    @Test func splitsOnLongPauses() {
        let input = words("first part", start: 0) + words("second part", start: 5)
        let cues = CueBuilder.cues(from: input)
        #expect(cues.map(\.text) == ["first part", "second part"])
    }

    @Test func joinerForCJK() {
        #expect(CueBuilder.joiner(for: "ja_JP") == "")
        #expect(CueBuilder.joiner(for: "en_US") == " ")
    }

    @Test func srtAndVttFormatting() {
        let cues = [SubtitleCue(start: 1.5, end: 3.25, text: "Hello"), SubtitleCue(start: 3661.001, end: 3662, text: "World")]
        let srt = SubtitleExporter.string(for: cues, format: .srt)
        #expect(srt.hasPrefix("1\n00:00:01,500 --> 00:00:03,250\nHello\n"))
        #expect(srt.contains("2\n01:01:01,001 --> 01:01:02,000\nWorld"))
        let vtt = SubtitleExporter.string(for: cues, format: .vtt)
        #expect(vtt.hasPrefix("WEBVTT\n\n00:00:01.500 --> 00:00:03.250\nHello"))
    }

    @Test func cuesShiftAndClipToTheVideo() {
        let cues = [SubtitleCue(start: 0, end: 2, text: "a"), SubtitleCue(start: 4, end: 6, text: "b"),
                    SubtitleCue(start: 9, end: 12, text: "c")]
        let shifted = SubtitleExporter.cues(cues, timeline: TimelineMap(ranges: [1..<10]))
        #expect(shifted.map(\.text) == ["a", "b", "c"])
        #expect(shifted[0].start == 0 && shifted[0].end == 1)
        #expect(shifted[1].start == 3)
        #expect(shifted[2].end == 9)
        #expect(SubtitleExporter.cues(cues, timeline: TimelineMap(ranges: [6.5..<8])).isEmpty)
    }

    @Test func rendersSubtitleImage() throws {
        let image = try #require(SubtitleRenderer.render(text: "Hello subtitles", style: SubtitleStyle(), fontSize: 48, maxWidth: 1600))
        #expect(image.width > 200 && image.width < 1600)
        #expect(image.height > 48 && image.height < 140)
    }

    @Test func outlinesLettersWithoutABox() throws {
        var style = SubtitleStyle()
        style.backgroundColor = .black.withAlpha(0)
        style.shadow = false
        // Opaque pixels that are dark: only the outline can make them.
        func darkPixels(_ style: SubtitleStyle) throws -> Int {
            let image = try #require(SubtitleRenderer.render(text: "Hello", style: style, fontSize: 48, maxWidth: 1600))
            let context = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                                 bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            let pixels = try #require(context.data).bindMemory(to: UInt8.self, capacity: image.width * image.height * 4)
            return (0..<(image.width * image.height)).filter { pixels[$0 * 4 + 3] > 200 && pixels[$0 * 4] < 60 }.count
        }
        #expect(try darkPixels(style) == 0)
        style.outlineWidth = 0.12
        #expect(try darkPixels(style) > 200)
    }

    @Test func decodesSubtitleStylesFromBeforeOutlines() throws {
        let json = #"{"isEnabled":true,"fontScale":0.05,"position":"top","textColor":{"red":1,"green":1,"blue":1,"alpha":1},"backgroundColor":{"red":0,"green":0,"blue":0,"alpha":0.5},"bold":false}"#
        let style = try JSONDecoder().decode(SubtitleStyle.self, from: Data(json.utf8))
        #expect(style.fontScale == 0.05 && style.position == .top && !style.bold)
        #expect(style.outlineWidth == 0 && style.shadow)
    }

    @Test func sectionsCanHaveTheirOwnSubtitleStyle() throws {
        var edit = EditSettings()
        edit.setSubtitleStyle(from: 4, to: nil, duration: 10) { $0.outlineWidth = 0.1 }
        #expect(edit.sections.map(\.start) == [0, 4])
        #expect(edit.subtitleStyle(at: 2).outlineWidth == 0)
        #expect(edit.subtitleStyle(at: 6).outlineWidth == 0.1)
        // The recording's switch still turns them off everywhere.
        edit.subtitles.isEnabled = false
        #expect(!edit.subtitleStyle(at: 6).isEnabled)

        // A section keeps its style through a round trip, and older sections decode without one.
        let decoded = try JSONDecoder().decode(EditSettings.self, from: JSONEncoder().encode(edit))
        #expect(decoded.sections[1].subtitles?.outlineWidth == 0.1)
        #expect(decoded.sections[0].subtitles == nil)
    }
}

@Suite struct TranscriptionChunkingTests {
    @Test func quietAudioIsNormalized() {
        var quiet: [Float] = [0.01, -0.05, 0.1, -0.02]
        TranscriptionEngine.normalize(&quiet)
        #expect(abs(quiet.map(abs).max()! - 0.7) < 0.001)
        var silence: [Float] = [0, 0.0001, -0.0002]
        TranscriptionEngine.normalize(&silence)
        #expect(silence == [0, 0.0001, -0.0002]) // noise floor isn't amplified
        var loud: [Float] = [0.9, -0.95]
        TranscriptionEngine.normalize(&loud)
        #expect(loud == [0.9, -0.95])
    }

    @Test func shortAudioIsOneChunk() {
        let rate = Int(TranscriptionEngine.sampleRate)
        let count = rate * 20
        let energy = [Float](repeating: 1, count: count / TranscriptionEngine.frameLength)
        #expect(TranscriptionEngine.chunkRanges(sampleCount: count, energy: energy) == [0..<count])
    }

    @Test func cutsAtTheQuietestMoment() {
        let rate = Int(TranscriptionEngine.sampleRate)
        var samples = (0..<(rate * 100)).map { index in Float(sin(Double(index) * 0.05)) * 0.5 }
        // Silence around 27 s and 61 s.
        for second in [27, 61] {
            for index in (second * rate)..<(second * rate + rate / 2) { samples[index] = 0 }
        }
        let ranges = TranscriptionEngine.chunkRanges(sampleCount: samples.count, energy: TranscriptionEngine.frameEnergies(samples))
        #expect(ranges.count >= 3)
        #expect(ranges.first?.lowerBound == 0)
        #expect(ranges.last?.upperBound == samples.count)
        for (a, b) in zip(ranges, ranges.dropFirst()) { #expect(a.upperBound == b.lowerBound) }
        let firstCut = Double(ranges[0].upperBound) / TranscriptionEngine.sampleRate
        #expect(firstCut > 27 && firstCut < 27.5)
        #expect(ranges.allSatisfy { Double($0.count) / TranscriptionEngine.sampleRate <= 40.01 })
    }

    @Test func resultsAddUpWithoutLosingWords() {
        func word(_ text: String, _ start: Double) -> TranscriptWord { TranscriptWord(text: text, start: start, end: start + 0.5) }
        var words: [TranscriptWord] = []
        // One result per utterance.
        TranscriptionEngine.merge([word("Hello", 30), word("there", 30.5)], into: &words)
        TranscriptionEngine.merge([word("and", 34), word("welcome", 34.5)], into: &words)
        #expect(words.map(\.text) == ["Hello", "there", "and", "welcome"])
        // A cumulative result replaces what it repeats.
        TranscriptionEngine.merge([word("Hello", 30), word("there,", 30.5), word("and", 34), word("welcome", 34.5),
                                   word("back", 35)], into: &words)
        #expect(words.map(\.text) == ["Hello", "there,", "and", "welcome", "back"])
        // An empty result at the start of the chunk (as some requests end with) keeps everything.
        TranscriptionEngine.merge([TranscriptWord(text: "", start: 30, end: 30)], into: &words)
        TranscriptionEngine.merge([], into: &words)
        #expect(words.count == 5)
    }
}

@Suite struct ExportSizeTests {
    @Test func resolutionPresetsNeverUpscale() {
        let canvas = CGSize(width: 1280, height: 720)
        var options = ExportOptions()
        options.resolution = .uhd
        #expect(VideoExporter.renderSize(canvas: canvas, options: options) == canvas)
        options.resolution = .hd
        #expect(VideoExporter.renderSize(canvas: canvas, options: options) == canvas)
    }

    @Test func h264IsKeptWithinLimits() {
        let canvas = CGSize(width: 5120, height: 2880)
        var options = ExportOptions()
        options.resolution = .original
        options.codec = .h264
        let size = VideoExporter.renderSize(canvas: canvas, options: options)
        #expect(size.width <= 4096)
        options.codec = .hevc
        #expect(VideoExporter.renderSize(canvas: canvas, options: options) == canvas)
    }

    @Test func shortSideMatchesPreset() {
        var options = ExportOptions()
        options.resolution = .fullHD
        let portrait = VideoExporter.renderSize(canvas: CGSize(width: 2160, height: 3840), options: options)
        #expect(portrait == CGSize(width: 1080, height: 1920))
    }

    @Test func aspectPresetsExportAtExactStandardSizes() {
        // A 3420×2136 window on a 16:9 canvas rounds to 3796×2136; 1080p must still be 1920×1080.
        let source = CGSize(width: 3420, height: 2136)
        var options = ExportOptions()
        options.resolution = .fullHD
        for (aspect, expected) in [(AspectPreset.landscape, CGSize(width: 1920, height: 1080)),
                                   (.portrait, CGSize(width: 1080, height: 1920)),
                                   (.square, CGSize(width: 1080, height: 1080))] {
            let canvas = LayoutEngine.canvasSize(source: source, aspect: aspect)
            #expect(VideoExporter.renderSize(canvas: canvas, ratio: aspect.ratio, options: options) == expected)
        }
    }

    @Test func fileNamesAreSanitized() {
        #expect(EditorModel.fileName(for: "Demo: v1/v2?") == "Demo- v1-v2-")
        #expect(EditorModel.fileName(for: "   ") == "Recording")
    }
}
