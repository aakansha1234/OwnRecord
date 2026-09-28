@preconcurrency import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

enum Thumbnailer {
    static func image(from asset: AVAsset, at seconds: Double, maxSize: CGSize,
                      videoComposition: AVVideoComposition? = nil) async -> CGImage? {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = maxSize
        generator.videoComposition = videoComposition
        generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 2)
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 2)
        return try? await generator.image(at: seconds.cmTime).image
    }

    static func writeJPEG(_ image: CGImage, to url: URL, quality: Double = 0.82) {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        CGImageDestinationFinalize(destination)
    }
}
