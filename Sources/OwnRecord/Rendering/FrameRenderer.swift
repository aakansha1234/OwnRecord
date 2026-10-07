import CoreImage
import CoreImage.CIFilterBuiltins

/// What a render produces: the finished frame, or one source on its own (for editing elsewhere).
enum RenderLayer: Sendable {
    /// Screen, camera, background and subtitles, as in the preview.
    case composed
    /// Only the screen (cropped, blurs and subtitles included), filling the frame. Black where it's hidden.
    case screen
    /// The whole screen recording, uncropped and with its blurs, filling the frame: what the crop is
    /// chosen from.
    case fullScreen
    /// Only the camera, filling the frame. Black where it's hidden.
    case camera
}

/// Snapshot of everything the compositor needs to draw a frame.
struct RenderState {
    var edit: EditSettings
    var cues: [SubtitleCue]
    /// Maps composition time back to recording time (sections and subtitles use recording time).
    var timeline: TimelineMap
    var sourceSize: CGSize
    var hasCamera: Bool
    /// Use Lanczos downscaling (slower, sharper text). Enabled for exports.
    var highQuality: Bool
    var layer = RenderLayer.composed
}

/// Composes screen, camera and subtitles into one frame with Core Image.
enum FrameRenderer {
    static func render(screen: CIImage?, camera: CIImage?, outputTime: Double, state: RenderState, canvas: CGSize) -> CIImage {
        let sourceTime = state.timeline.sourceTime(forOutput: outputTime)
        let layout = LayoutEngine.layout(canvas: canvas, source: state.sourceSize, edit: state.edit,
                                         hasCamera: state.hasCamera && camera != nil, at: sourceTime,
                                         timeline: state.timeline)
        let bounds = CGRect(origin: .zero, size: canvas)
        let minSide = min(canvas.width, canvas.height)
        let redactions = state.edit.section(at: sourceTime).redactions

        switch state.layer {
        case .composed:
            break
        case .screen:
            var output = CIImage(color: .black).cropped(to: bounds)
            if let screen, layout.screenOpacity > 0.001 {
                let content = place(cropped(redacted(screen, redactions), to: state.edit.crop), in: bounds,
                                    highQuality: state.highQuality)
                output = faded(content, layout.screenOpacity).composited(over: output)
            }
            return subtitled(output, at: sourceTime, layout: layout, state: state).cropped(to: bounds)
        case .camera:
            var output = CIImage(color: .black).cropped(to: bounds)
            if let camera, let frame = layout.camera, frame.opacity > 0.001 {
                var feed = aspectFillCrop(camera, to: canvas)
                if state.edit.camera.mirror { feed = mirrored(feed) }
                output = faded(place(feed, in: bounds, highQuality: state.highQuality), frame.opacity).composited(over: output)
            }
            return output.cropped(to: bounds)
        case .fullScreen:
            let output = CIImage(color: .black).cropped(to: bounds)
            guard let screen else { return output }
            return place(redacted(screen, redactions), in: bounds, highQuality: state.highQuality).composited(over: output)
        }

        var output = background(state.edit.layout.background, canvas: canvas)

        if let screen, layout.screenOpacity > 0.001 {
            let target = flipped(layout.screenRect, canvasHeight: canvas.height)
            var content = place(cropped(redacted(screen, redactions), to: state.edit.crop), in: target,
                                highQuality: state.highQuality)
            if layout.screenCornerRadius > 0.5 {
                content = masked(content, rect: target, radius: layout.screenCornerRadius)
            }
            if state.edit.layout.shadow > 0, state.edit.layout.padding > 0.001 {
                let strength = CGFloat(state.edit.layout.shadow) * layout.screenOpacity
                output = shadow(rect: target, radius: layout.screenCornerRadius, blur: minSide * 0.025,
                                opacity: 0.55 * strength, offsetY: minSide * 0.012).composited(over: output)
            }
            output = faded(content, layout.screenOpacity).composited(over: output)
        }

        if let camera, let frame = layout.camera, frame.opacity > 0.001 {
            let style = state.edit.camera
            let rect = frame.rect
            let target = flipped(rect, canvasHeight: canvas.height)
            let radius = frame.cornerRadius
            var overlay = CIImage.empty()
            let coversCanvas = rect.insetBy(dx: -1, dy: -1).contains(bounds)
            if style.shadow, !coversCanvas {
                overlay = shadow(rect: target, radius: radius, blur: min(rect.height * 0.06, minSide * 0.03), opacity: 0.45,
                                 offsetY: min(rect.height * 0.025, minSide * 0.012))
            }
            var inner = target
            var innerRadius = radius
            if frame.borderWidth > 0.5 {
                overlay = roundedRect(target, radius: radius, color: style.borderColor.ciColor).composited(over: overlay)
                inner = target.insetBy(dx: frame.borderWidth, dy: frame.borderWidth)
                innerRadius = max(0, radius - frame.borderWidth)
            }
            var feed = aspectFillCrop(camera, to: inner.size)
            if style.mirror { feed = mirrored(feed) }
            feed = masked(place(feed, in: inner, highQuality: state.highQuality && frame.fillsStage), rect: inner, radius: innerRadius)
            overlay = feed.composited(over: overlay)
            output = faded(overlay, frame.opacity).composited(over: output)
        }

        return subtitled(output, at: sourceTime, layout: layout, state: state).cropped(to: bounds)
    }

    /// Draws the subtitle playing at `sourceTime` over `image`, if subtitles are on.
    private static func subtitled(_ image: CIImage, at sourceTime: Double, layout: CanvasLayout, state: RenderState) -> CIImage {
        let style = state.edit.subtitleStyle(at: sourceTime)
        guard style.isEnabled,
              let cue = state.cues.first(where: { sourceTime >= $0.start && sourceTime < $0.end }),
              let text = SubtitleRenderer.shared.image(text: cue.text, style: style,
                                                       fontSize: layout.subtitleFontSize, maxWidth: layout.subtitleMaxWidth)
        else { return image }
        let canvas = layout.canvas
        let x = ((canvas.width - text.extent.width) / 2).rounded()
        let y = style.position == .bottom
            ? layout.subtitleMargin
            : canvas.height - layout.subtitleMargin - text.extent.height
        return text.transformed(by: CGAffineTransform(translationX: x, y: y.rounded())).composited(over: image)
    }

    /// Blurs or pixelates the given areas of a screen frame. Each area only samples its own
    /// pixels, so nothing around it bleeds in or out.
    static func redacted(_ image: CIImage, _ redactions: [Redaction]) -> CIImage {
        let extent = image.extent
        guard !redactions.isEmpty, extent.width > 0, extent.height > 0 else { return image }
        let shortSide = min(extent.width, extent.height)
        var output = image
        for redaction in redactions {
            let rect = redaction.pixelRect(in: extent.size).offsetBy(dx: extent.minX, dy: extent.minY).intersection(extent)
            guard !rect.isEmpty else { continue }
            let region = output.cropped(to: rect).clampedToExtent()
            let hidden: CIImage
            switch redaction.style {
            case .blur:
                // Strong enough to make text of any size unreadable.
                hidden = region.applyingGaussianBlur(sigma: Double(max(6, shortSide * 0.012)))
            case .pixelate:
                hidden = region.applyingFilter("CIPixellate", parameters: [
                    kCIInputCenterKey: CIVector(x: rect.minX, y: rect.minY),
                    kCIInputScaleKey: max(8, shortSide * 0.022),
                ])
            }
            output = hidden.cropped(to: rect).composited(over: output)
        }
        return output
    }

    /// The part of a screen frame that `crop` keeps.
    static func cropped(_ image: CIImage, to crop: CropRect?) -> CIImage {
        let extent = image.extent
        guard let crop, extent.width > 0, extent.height > 0, extent.width.isFinite, extent.height.isFinite else { return image }
        let rect = flipped(crop.pixelRect(in: extent.size), canvasHeight: extent.height)
        return image.cropped(to: rect.offsetBy(dx: extent.minX, dy: extent.minY))
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

    /// Multiplies the image's alpha (for fades).
    static func faded(_ image: CIImage, _ opacity: CGFloat) -> CIImage {
        guard opacity < 0.999 else { return image }
        return image.applyingFilter("CIColorMatrix", parameters: [
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: max(0, opacity)),
        ])
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
