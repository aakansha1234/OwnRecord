import CoreImage
import CoreImage.CIFilterBuiltins

/// Snapshot of everything the compositor needs to draw a frame.
struct RenderState {
    var edit: EditSettings
    var cues: [SubtitleCue]
    /// Added to composition time to get recording (source) time, e.g. the trim start on export.
    var timeOffset: Double
    var sourceSize: CGSize
    var hasCamera: Bool
    /// Use Lanczos downscaling (slower, sharper text). Enabled for exports.
    var highQuality: Bool
}

/// Composes screen, camera and subtitles into one frame with Core Image.
enum FrameRenderer {
    static func render(screen: CIImage?, camera: CIImage?, sourceTime: Double, state: RenderState, canvas: CGSize) -> CIImage {
        let layout = LayoutEngine.layout(canvas: canvas, source: state.sourceSize, edit: state.edit,
                                         hasCamera: state.hasCamera && camera != nil)
        let bounds = CGRect(origin: .zero, size: canvas)
        let minSide = min(canvas.width, canvas.height)
        var output = background(state.edit.layout.background, canvas: canvas)

        if let screen {
            let target = flipped(layout.screenRect, canvasHeight: canvas.height)
            var content = place(screen, in: target, highQuality: state.highQuality)
            if layout.screenCornerRadius > 0.5 {
                content = masked(content, rect: target, radius: layout.screenCornerRadius)
            }
            if state.edit.layout.shadow > 0, state.edit.layout.padding > 0.001 {
                let strength = CGFloat(state.edit.layout.shadow)
                output = shadow(rect: target, radius: layout.screenCornerRadius, blur: minSide * 0.025,
                                opacity: 0.55 * strength, offsetY: minSide * 0.012).composited(over: output)
            }
            output = content.composited(over: output)
        }

        if let camera, let rect = layout.cameraRect {
            let style = state.edit.camera
            let target = flipped(rect, canvasHeight: canvas.height)
            let radius = layout.cameraCornerRadius
            if style.shadow {
                output = shadow(rect: target, radius: radius, blur: rect.height * 0.06, opacity: 0.45,
                                offsetY: rect.height * 0.025).composited(over: output)
            }
            let border = CGFloat(style.borderWidth) * rect.height
            var inner = target
            var innerRadius = radius
            if border > 0.5 {
                output = roundedRect(target, radius: radius, color: style.borderColor.ciColor).composited(over: output)
                inner = target.insetBy(dx: border, dy: border)
                innerRadius = max(0, radius - border)
            }
            var feed = aspectFillCrop(camera, to: inner.size)
            if style.mirror { feed = mirrored(feed) }
            feed = masked(place(feed, in: inner, highQuality: false), rect: inner, radius: innerRadius)
            output = feed.composited(over: output)
        }

        if state.edit.subtitles.isEnabled,
           let cue = state.cues.first(where: { sourceTime >= $0.start && sourceTime < $0.end }),
           let text = SubtitleRenderer.shared.image(text: cue.text, style: state.edit.subtitles,
                                                    fontSize: layout.subtitleFontSize, maxWidth: layout.subtitleMaxWidth) {
            let x = ((canvas.width - text.extent.width) / 2).rounded()
            let y = state.edit.subtitles.position == .bottom
                ? layout.subtitleMargin
                : canvas.height - layout.subtitleMargin - text.extent.height
            output = text.transformed(by: CGAffineTransform(translationX: x, y: y.rounded())).composited(over: output)
        }

        return output.cropped(to: bounds)
    }

    // MARK: Helpers

    /// Converts a top-left-origin rect into Core Image's bottom-left space.
    static func flipped(_ rect: CGRect, canvasHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: canvasHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    static func background(_ preset: BackgroundPreset, canvas: CGSize) -> CIImage {
        let bounds = CGRect(origin: .zero, size: canvas)
        let colors = preset.colors
        guard colors.count == 2, colors[0] != colors[1] else {
            return CIImage(color: colors[0].ciColor).cropped(to: bounds)
        }
        let gradient = CIFilter.linearGradient()
        gradient.point0 = CGPoint(x: 0, y: canvas.height)
        gradient.point1 = CGPoint(x: canvas.width, y: 0)
        gradient.color0 = colors[0].ciColor
        gradient.color1 = colors[1].ciColor
        return (gradient.outputImage ?? CIImage(color: .black)).cropped(to: bounds)
    }

    /// Scales and moves `image` to exactly fill `rect`.
    static func place(_ image: CIImage, in rect: CGRect, highQuality: Bool) -> CIImage {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0, rect.width > 0, rect.height > 0 else { return .empty() }
        let scaleX = rect.width / extent.width
        let scaleY = rect.height / extent.height
        var result = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .clampedToExtent()
        if highQuality, scaleY < 0.99 {
            result = result.applyingFilter("CILanczosScaleTransform", parameters: [
                kCIInputScaleKey: scaleY,
                kCIInputAspectRatioKey: scaleX / scaleY,
            ])
        } else {
            result = result.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
        }
        return result.transformed(by: CGAffineTransform(translationX: rect.minX, y: rect.minY)).cropped(to: rect)
    }

    static func aspectFillCrop(_ image: CIImage, to size: CGSize) -> CIImage {
        let extent = image.extent
        guard size.width > 0, size.height > 0, extent.width > 0, extent.height > 0 else { return image }
        let target = size.width / size.height
        let current = extent.width / extent.height
        let crop: CGRect
        if current > target {
            let width = extent.height * target
            crop = CGRect(x: extent.midX - width / 2, y: extent.minY, width: width, height: extent.height)
        } else {
            let height = extent.width / target
            crop = CGRect(x: extent.minX, y: extent.midY - height / 2, width: extent.width, height: height)
        }
        return image.cropped(to: crop)
    }

    static func mirrored(_ image: CIImage) -> CIImage {
        let extent = image.extent
        return image.transformed(by: CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: extent.minX + extent.maxX, ty: 0))
    }

    static func roundedRect(_ rect: CGRect, radius: CGFloat, color: CIColor) -> CIImage {
        let generator = CIFilter.roundedRectangleGenerator()
        generator.extent = rect
        generator.radius = Float(min(radius, min(rect.width, rect.height) / 2))
        generator.color = color
        return generator.outputImage ?? .empty()
    }

    static func masked(_ image: CIImage, rect: CGRect, radius: CGFloat) -> CIImage {
        let shape = roundedRect(rect, radius: radius, color: .white)
        return image.applyingFilter("CISourceInCompositing", parameters: [kCIInputBackgroundImageKey: shape])
    }

    static func shadow(rect: CGRect, radius: CGFloat, blur: CGFloat, opacity: CGFloat, offsetY: CGFloat) -> CIImage {
        roundedRect(rect, radius: radius, color: CIColor(red: 0, green: 0, blue: 0, alpha: opacity))
            .applyingGaussianBlur(sigma: Double(blur))
            .transformed(by: CGAffineTransform(translationX: 0, y: -offsetY))
    }
}
