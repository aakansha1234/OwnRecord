import CoreImage
import Foundation
@testable import OwnRecord
import Testing

@Suite struct CropTests {
    private let size = CGSize(width: 1000, height: 500)
    private let start = CGRect(x: 100, y: 100, width: 400, height: 200)

    private func resized(_ handle: CropHandle, by dx: CGFloat, _ dy: CGFloat, ratio: CGFloat? = nil,
                         fromCenter: Bool = false, from start: CGRect? = nil) -> CGRect {
        CropRect.resizing(start ?? self.start, handle: handle, by: CGSize(width: dx, height: dy), in: size,
                          ratio: ratio, fromCenter: fromCenter)
    }

    @Test func cropsStayInsideTheRecordingOnEvenPixels() {
        let crop = CropRect(rect: CGRect(x: 0.9, y: -0.2, width: 0.3, height: 0.001))
        #expect(crop.width == 0.3)
        #expect(crop.height == CropRect.minimumSide)
        #expect(abs(crop.x - 0.7) < 1e-9)
        #expect(crop.y == 0)
        #expect(CropRect.full.isFull)
        #expect(!crop.isFull)

        // Whole pixels with an even size, as encoders need.
        let pixels = CropRect(rect: CGRect(x: 0.1, y: 0.1, width: 0.333, height: 0.5)).pixelRect(in: CGSize(width: 1001, height: 601))
        #expect(pixels == CGRect(x: 100, y: 60, width: 332, height: 300))
        #expect(CropRect.full.pixelRect(in: CGSize(width: 640, height: 400)) == CGRect(x: 0, y: 0, width: 640, height: 400))
        // Pixels round-trip.
        let source = CGSize(width: 1920, height: 1080)
        #expect(CropRect(pixels: CGRect(x: 0, y: 50, width: 1920, height: 1030), in: source).pixelRect(in: source)
            == CGRect(x: 0, y: 50, width: 1920, height: 1030))
    }

    @Test func handlesResizeFreely() {
        #expect(resized(.bottomRight, by: 100, 50) == CGRect(x: 100, y: 100, width: 500, height: 250))
        #expect(resized(.right, by: 100, 50) == CGRect(x: 100, y: 100, width: 500, height: 200))
        // Stops at the edge of the recording.
        #expect(resized(.left, by: -200, 0) == CGRect(x: 0, y: 100, width: 500, height: 200))
        // Dragged past the opposite corner: the smallest crop, against that corner.
        #expect(resized(.topLeft, by: 1000, 1000) == CGRect(x: 450, y: 275, width: 50, height: 25))
        // ⌥ resizes around the center.
        #expect(resized(.right, by: 50, 0, fromCenter: true) == CGRect(x: 50, y: 100, width: 500, height: 200))
    }

    @Test func handlesKeepALockedShape() {
        // A corner follows the side pulled further.
        #expect(resized(.bottomRight, by: 200, 0, ratio: 2) == CGRect(x: 100, y: 100, width: 600, height: 300))
        // An edge grows the other side around the middle.
        #expect(resized(.right, by: 200, 0, ratio: 2) == CGRect(x: 100, y: 50, width: 600, height: 300))
        // …shifting to stay inside the recording.
        #expect(resized(.bottom, by: 0, 100, ratio: 1, from: CGRect(x: 0, y: 100, width: 200, height: 200))
            == CGRect(x: 0, y: 100, width: 300, height: 300))
        // Too big: shrinks, keeping the shape.
        #expect(resized(.bottomRight, by: 2000, 0, ratio: 2) == CGRect(x: 100, y: 100, width: 800, height: 400))
    }

    @Test func choosingAShapeFitsItInsideTheCrop() {
        #expect(CropRect.conforming(start, to: 1, in: size) == CGRect(x: 200, y: 100, width: 200, height: 200))
        let portrait = CropRect.conforming(CGRect(origin: .zero, size: size), to: 9.0 / 16.0, in: size)
        #expect(portrait.height == 500)
        #expect(abs(portrait.width - 281.25) < 0.01)
        #expect(abs(portrait.midX - 500) < 0.01)
    }

    @Test func theVideoIsLaidOutAroundTheCrop() {
        let source = CGSize(width: 2000, height: 1000)
        var edit = EditSettings()
        edit.crop = CropRect(pixels: CGRect(x: 600, y: 0, width: 1000, height: 1000), in: source)
        // Auto follows the crop's shape, at its size (never upscaled).
        #expect(LayoutEngine.canvasSize(source: source, edit: edit) == CGSize(width: 1000, height: 1000))
        edit.layout.aspect = .landscape
        let canvas = LayoutEngine.canvasSize(source: source, edit: edit)
        #expect(canvas.height == 1000)
        let screen = LayoutEngine.layout(canvas: canvas, source: source, edit: edit, hasCamera: false).screenRect
        #expect(abs(screen.width - screen.height) < 0.5)
        #expect(abs(screen.midX - canvas.width / 2) < 0.5)
    }

    @Test func rendersOnlyTheCroppedPart() {
        // Left half blue, right half red (Core Image is bottom-up, so "left" is the same either way).
        let source = CGSize(width: 400, height: 200)
        let screen = CIImage(color: CIColor(red: 0, green: 0, blue: 1)).cropped(to: CGRect(x: 0, y: 0, width: 200, height: 200))
            .composited(over: CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: CGRect(origin: .zero, size: source)))
        var edit = EditSettings()
        edit.crop = CropRect(rect: CGRect(x: 0.5, y: 0, width: 0.5, height: 1))
        var state = RenderState(edit: edit, cues: [], timeline: .identity(duration: 1), sourceSize: source, hasCamera: false,
                                highQuality: false)

        func colors(canvas: CGSize) -> [(r: Int, b: Int)] {
            let image = FrameRenderer.render(screen: screen, camera: nil, outputTime: 0, state: state, canvas: canvas)
            let width = Int(canvas.width), height = Int(canvas.height)
            var data = [UInt8](repeating: 0, count: width * height * 4)
            CIContext().render(image, toBitmap: &data, rowBytes: width * 4, bounds: CGRect(origin: .zero, size: canvas),
                               format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
            // Left edge, middle and right edge of the middle row.
            return [2, width / 2, width - 3].map { x in
                let offset = ((height / 2) * width + x) * 4
                return (Int(data[offset]), Int(data[offset + 2]))
            }
        }

        let canvas = LayoutEngine.canvasSize(source: source, edit: edit)
        #expect(canvas == CGSize(width: 200, height: 200))
        for color in colors(canvas: canvas) {
            #expect(color.r > 200 && color.b < 60)
        }
        // While choosing the crop, the preview shows the whole recording.
        state.layer = .fullScreen
        let full = colors(canvas: source)
        #expect(full[0].b > 200 && full[0].r < 60)
        #expect(full[2].r > 200 && full[2].b < 60)
    }

    @Test func editsWithoutACropDecode() throws {
        let old = try JSONDecoder().decode(EditSettings.self, from: Data(#"{"trimStart":1}"#.utf8))
        #expect(old.crop == nil)
        var edit = EditSettings()
        edit.crop = CropRect(rect: CGRect(x: 0.1, y: 0.2, width: 0.5, height: 0.6))
        let decoded = try JSONDecoder().decode(EditSettings.self, from: JSONEncoder().encode(edit))
        #expect(decoded.crop == edit.crop)
    }

    @Test func commandLineCropsAreChecked() throws {
        let source = CGSize(width: 1920, height: 1080)
        let pixels = try #require(try CropRect(rect: nil, pixels: [0, 54, 960, 540], in: source))
        #expect(pixels.pixelRect(in: source) == CGRect(x: 0, y: 54, width: 960, height: 540))
        // The whole recording is no crop at all.
        #expect(try CropRect(rect: [0, 0, 1, 1], pixels: nil, in: source) == nil)
        #expect(throws: ControlError.self) { try CropRect(rect: [0.5, 0, 0.6, 1], pixels: nil, in: source) }
        #expect(throws: ControlError.self) { try CropRect(rect: nil, pixels: [0, 0, 20, 20], in: source) }
        #expect(throws: ControlError.self) { try CropRect(rect: nil, pixels: nil, in: source) }
        // A usage error is reported without contacting the app.
        #expect(CommandLineTool.run(["/usr/local/bin/ownrecord", "crop", "latest"]) == 2)
        #expect(CommandLineTool.run(["/usr/local/bin/ownrecord", "crop", "latest", "--reset", "--px", "0,0,10,10"]) == 2)
    }
}
