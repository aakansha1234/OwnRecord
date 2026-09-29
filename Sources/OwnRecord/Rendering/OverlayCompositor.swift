@preconcurrency import AVFoundation
import CoreImage
import Metal

/// Carries the render state for a time range of the composition to the compositor.
final class OverlayInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid

    let screenTrackID: CMPersistentTrackID
    let cameraTrackID: CMPersistentTrackID?
    let state: RenderState

    init(timeRange: CMTimeRange, screenTrackID: CMPersistentTrackID, cameraTrackID: CMPersistentTrackID?, state: RenderState) {
        self.timeRange = timeRange
        self.screenTrackID = screenTrackID
        self.cameraTrackID = cameraTrackID
        self.state = state
        requiredSourceTrackIDs = ([screenTrackID] + (cameraTrackID.map { [$0] } ?? [])).map { NSNumber(value: $0) }
    }
}

/// Custom video compositor used by both the editor preview and exports.
final class OverlayCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    private static let context: CIContext = {
        // Blend in (non-linear) sRGB like design tools and CSS do, so translucent subtitle
        // boxes, shadows and gradients look the way their settings suggest.
        let options: [CIContextOption: Any] = [
            .cacheIntermediates: false,
            .name: "OwnRecordCompositor",
            .workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        ]
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device, options: options)
        }
        return CIContext(options: options)
    }()

    private static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private let renderQueue = DispatchQueue(label: "com.ownrecord.compositor", qos: .userInitiated)

    private static let pixelBufferAttributes: [String: any Sendable] = [
        kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_32BGRA],
        kCVPixelBufferMetalCompatibilityKey as String: true,
    ]

    var sourcePixelBufferAttributes: [String: any Sendable]? { Self.pixelBufferAttributes }
    var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] { Self.pixelBufferAttributes }

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        renderQueue.async {
            autoreleasepool { Self.render(request) }
        }
    }

    func cancelAllPendingVideoCompositionRequests() {}

    private static func render(_ request: AVAsynchronousVideoCompositionRequest) {
        guard let instruction = request.videoCompositionInstruction as? OverlayInstruction else {
            request.finish(with: NSError(domain: "OwnRecord", code: 1,
                                         userInfo: [NSLocalizedDescriptionKey: "Unexpected composition instruction."]))
            return
        }
        guard let output = request.renderContext.newPixelBuffer() else {
            request.finish(with: NSError(domain: "OwnRecord", code: 2,
                                         userInfo: [NSLocalizedDescriptionKey: "Couldn't allocate a frame."]))
            return
        }
        let screen = request.sourceFrame(byTrackID: instruction.screenTrackID).map { CIImage(cvPixelBuffer: $0) }
        let camera = instruction.cameraTrackID
            .flatMap { request.sourceFrame(byTrackID: $0) }
            .map { CIImage(cvPixelBuffer: $0) }
        let size = request.renderContext.size
        let image = FrameRenderer.render(screen: screen, camera: camera, outputTime: request.compositionTime.seconds,
                                         state: instruction.state, canvas: size)
        CVBufferSetAttachment(output, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(output, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(output, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        context.render(image, to: output, bounds: CGRect(origin: .zero, size: size), colorSpace: colorSpace)
        request.finish(withComposedVideoFrame: output)
    }
}
