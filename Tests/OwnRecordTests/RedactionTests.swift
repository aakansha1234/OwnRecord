import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
@testable import OwnRecord
import Testing

@Suite struct RedactionTests {
    /// A 4 px black-and-white checkerboard: sharp detail that a blur or pixelation has to wipe out.
    private func checkerboard(size: CGSize) -> CIImage {
        let generator = CIFilter.checkerboardGenerator()
        generator.color0 = .black
        generator.color1 = .white
        generator.width = 4
        generator.center = .zero
        return generator.outputImage!.cropped(to: CGRect(origin: .zero, size: size))
    }

    /// Gray values (0...255) of `image`, rows from the top.
    private func grays(_ image: CIImage, size: CGSize) -> [[Int]] {
        let width = Int(size.width), height = Int(size.height)
        var data = [UInt8](repeating: 0, count: width * height * 4)
        CIContext().render(image, toBitmap: &data, rowBytes: width * 4, bounds: CGRect(origin: .zero, size: size),
                           format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return (0..<height).map { row in (0..<width).map { Int(data[(row * width + $0) * 4]) } }
    }

    /// Spread of gray values in a top-left-origin rect.
    private func contrast(_ grays: [[Int]], _ rect: CGRect) -> Int {
        var values: [Int] = []
        for y in Int(rect.minY)..<Int(rect.maxY) {
            for x in Int(rect.minX)..<Int(rect.maxX) { values.append(grays[y][x]) }
        }
        return (values.max() ?? 0) - (values.min() ?? 0)
    }

    @Test(arguments: RedactionStyle.allCases)
    func hidesDetailOnlyInsideTheArea(style: RedactionStyle) {
        let size = CGSize(width: 400, height: 300)
        let redaction = Redaction(style: style, rect: CGRect(x: 0.25, y: 0.2, width: 0.5, height: 0.4))
        let output = grays(FrameRenderer.redacted(checkerboard(size: size), [redaction]), size: size)

        // Inside (top-left origin: x 100...300, y 60...180), away from the edges.
        let inside = contrast(output, CGRect(x: 130, y: 90, width: 140, height: 60))
        // The checkerboard averages to gray when blurred; pixelated blocks are gray too.
        #expect(inside < 40, "\(style) left detail visible: contrast \(inside)")
        // Outside is untouched.
        #expect(contrast(output, CGRect(x: 10, y: 10, width: 60, height: 30)) > 200)
        #expect(contrast(output, CGRect(x: 320, y: 200, width: 60, height: 60)) > 200)
    }

    @Test func areasStayInsideTheRecording() {
        var redaction = Redaction(rect: CGRect(x: 0.9, y: -0.2, width: 0.3, height: 0.001))
        #expect(redaction.width == 0.3)
        #expect(redaction.height == Redaction.minimumSide)
        #expect(abs(redaction.x - 0.7) < 1e-9)
        #expect(redaction.y == 0)
        redaction.rect = CGRect(x: 0.5, y: 0.5, width: 2, height: 2)
        #expect(redaction.rect == CGRect(x: 0, y: 0, width: 1, height: 1))
        // Core Image space is bottom-up.
        let pixels = Redaction(rect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.3)).pixelRect(in: CGSize(width: 100, height: 100))
        #expect(pixels == CGRect(x: 10, y: 60, width: 20, height: 30))
    }

    @Test func splitsCopyAreasAndOldEditsDecode() throws {
        var edit = EditSettings()
        edit.sections[0].redactions = [Redaction(style: .pixelate, rect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2))]
        edit.split(at: 1, duration: 2)
        #expect(edit.sections.count == 2)
        #expect(edit.sections[1].redactions == edit.sections[0].redactions)

        let decoded = try JSONDecoder().decode(EditSettings.self, from: JSONEncoder().encode(edit))
        #expect(decoded.sections[1].redactions.first?.style == .pixelate)

        // Joining keeps the blurred areas of both sections.
        let extra = Redaction(rect: CGRect(x: 0.6, y: 0.6, width: 0.2, height: 0.2))
        var joined = edit
        joined.sections[1].redactions.append(extra)
        joined.joinSection(at: 0)
        #expect(joined.sections.count == 1)
        #expect(joined.sections[0].redactions.map(\.id) == edit.sections[0].redactions.map(\.id) + [extra.id])

        let legacy = #"{"sections":[{"start":0,"showsScreen":false}]}"#
        let old = try JSONDecoder().decode(EditSettings.self, from: Data(legacy.utf8))
        #expect(old.sections[0].redactions.isEmpty)
        #expect(!old.sections[0].showsScreen)
    }
}

/// Writes blurred and pixelated versions of a real screenshot for visual review.
/// Opt-in: OWNRECORD_REDACTION_SAMPLE=/path/to/screenshot.png swift test --filter RedactionSamples
@Suite(.enabled(if: ProcessInfo.processInfo.environment["OWNRECORD_REDACTION_SAMPLE"] != nil))
struct RedactionSamples {
    @Test func writeSamples() throws {
        let path = try #require(ProcessInfo.processInfo.environment["OWNRECORD_REDACTION_SAMPLE"])
        let image = try #require(CIImage(contentsOf: URL(fileURLWithPath: path)))
        let output = SnapshotTests.outputDirectory
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let context = CIContext()
        for style in RedactionStyle.allCases {
            let areas = [Redaction(style: style, rect: CGRect(x: 0.1, y: 0.15, width: 0.35, height: 0.2)),
                         Redaction(style: style, rect: CGRect(x: 0.75, y: 0.15, width: 0.25, height: 0.3))]
            let result = FrameRenderer.redacted(image, areas)
            let url = output.appendingPathComponent("redaction-\(style.rawValue).png")
            try context.writePNGRepresentation(of: result, to: url, format: .RGBA8,
                                               colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        }
    }
}
