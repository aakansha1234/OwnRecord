import CoreGraphics

/// Resolved geometry of one output frame. All rects use a top-left origin.
struct CanvasLayout: Equatable {
    var canvas: CGSize
    var screenRect: CGRect
    var screenCornerRadius: CGFloat
    /// 0 when the section hides the screen; in between while animating.
    var screenOpacity: CGFloat
    var camera: CameraFrame?
    var subtitleFontSize: CGFloat
    var subtitleMaxWidth: CGFloat
    /// Distance from the top/bottom canvas edge to the subtitle box.
    var subtitleMargin: CGFloat

    var cameraRect: CGRect? { camera?.rect }
}

/// Where and how the camera is drawn in one frame.
struct CameraFrame: Equatable {
    var rect: CGRect
    var cornerRadius: CGFloat
    /// Border thickness in pixels.
    var borderWidth: CGFloat
    var opacity: CGFloat
    /// The camera takes the screen's place (the section hides the screen).
    var fillsStage: Bool
}

/// What a section shows, used to render it and to animate between sections.
struct SectionLook: Equatable {
    var showsScreen = true
    var showsCamera = true
    var placement = CameraPlacement()
}

/// Pure layout math shared by the compositor, the editor preview and tests.
/// Every style value is relative, so the same edit renders identically at any resolution.
enum LayoutEngine {
    static let maxCanvasLongSide: CGFloat = 3840

    /// Canvas size for an aspect preset: the smallest rect of that aspect that contains the
    /// source (so the screen is never upscaled), capped to 4K unless the source is larger.
    static func canvasSize(source: CGSize, aspect: AspectPreset) -> CGSize {
        guard source.width > 0, source.height > 0 else { return CGSize(width: 1920, height: 1080) }
        guard let ratio = aspect.ratio else { return source.evenRounded() }
        var size = source.width / source.height > ratio
            ? CGSize(width: source.width, height: source.width / ratio)
            : CGSize(width: source.height * ratio, height: source.height)
        let limit = max(maxCanvasLongSide, max(source.width, source.height))
        let longSide = max(size.width, size.height)
        if longSide > limit {
            size = size.scaled(limit / longSide)
        }
        return size.evenRounded()
    }

    /// How long layout changes between sections animate.
    static let transitionDuration = 0.4

    /// - Parameters:
    ///   - time: Recording time, which picks the section (and any transition into it).
    ///   - timeline: The video being rendered, to animate only from what actually plays before a
    ///     section (not from trimmed-away parts). Without it, the previous kept section is used.
    static func layout(canvas: CGSize, source: CGSize, edit: EditSettings, hasCamera: Bool, at time: Double = 0,
                       timeline: TimelineMap? = nil) -> CanvasLayout {
        let minSide = min(canvas.width, canvas.height)
        let padding = CGFloat(edit.layout.padding) * minSide
        let stage = CGRect(origin: .zero, size: canvas).insetBy(dx: padding, dy: padding)
        let screenRect = CGRect.aspectFit(source, in: stage)
        let screenRadius = CGFloat(edit.layout.cornerRadius) * min(screenRect.width, screenRect.height)

        let index = edit.sectionIndex(at: time)
        let look = self.look(of: edit.sections[index], edit: edit)
        var screenOpacity: CGFloat = look.showsScreen ? 1 : 0
        var camera = cameraFrame(for: look, edit: edit, canvas: canvas, stage: stage, hasCamera: hasCamera)
        if let previous = previousSection(before: index, edit: edit, timeline: timeline).map({ self.look(of: $0, edit: edit) }),
           previous != look {
            let progress = (time - edit.sections[index].start) / transitionDuration
            if progress < 1 {
                let eased = CGFloat(smoothstep(progress))
                screenOpacity = lerp(previous.showsScreen ? 1 : 0, screenOpacity, eased)
                let from = cameraFrame(for: previous, edit: edit, canvas: canvas, stage: stage, hasCamera: hasCamera)
                camera = interpolate(from, camera, eased)
            }
        }

        let fontSize = max(8, CGFloat(edit.subtitles.fontScale) * minSide)
        let margin = canvas.height * 0.06
        var halfWidth = canvas.width * 0.42
        if let camera, !camera.fillsStage, camera.opacity > 0.5 {
            // Keep subtitles clear of a camera overlay that shares their band.
            let bandHeight = fontSize * 2.8
            let band = edit.subtitles.position == .bottom
                ? CGRect(x: 0, y: canvas.height - margin - bandHeight, width: canvas.width, height: bandHeight)
                : CGRect(x: 0, y: margin, width: canvas.width, height: bandHeight)
            let rect = camera.rect
            if rect.minY < band.maxY, rect.maxY > band.minY {
                let centerX = canvas.width / 2
                if rect.minX > centerX {
                    halfWidth = min(halfWidth, rect.minX - centerX - fontSize * 0.5)
                } else if rect.maxX < centerX {
                    halfWidth = min(halfWidth, centerX - rect.maxX - fontSize * 0.5)
                }
            }
        }
        halfWidth = max(halfWidth, canvas.width * 0.2)

        return CanvasLayout(canvas: canvas, screenRect: screenRect, screenCornerRadius: screenRadius,
                            screenOpacity: screenOpacity, camera: camera,
                            subtitleFontSize: fontSize, subtitleMaxWidth: halfWidth * 2, subtitleMargin: margin)
    }

    /// The section that plays right before section `index` starts, if any.
    private static func previousSection(before index: Int, edit: EditSettings, timeline: TimelineMap?) -> TimelineSection? {
        guard let timeline else { return edit.sections[..<index].last { !$0.isDeleted } }
        let start = timeline.outputTime(forSource: edit.sections[index].start)
        guard index > 0, start > 1e-6 else { return nil }
        // Just before the section starts: the previous section, or whatever precedes a cut.
        let previous = edit.sectionIndex(at: timeline.sourceTime(forOutput: max(0, start - TimelineMap.endInset / 2)))
        return previous < index ? edit.sections[previous] : nil
    }

    static func look(of section: TimelineSection, edit: EditSettings) -> SectionLook {
        SectionLook(showsScreen: section.showsScreen, showsCamera: section.showsCamera,
                    placement: edit.cameraPlacement(for: section))
    }

    /// The camera for a section: a bubble over the screen, or filling the stage when the screen is hidden.
    static func cameraFrame(for look: SectionLook, edit: EditSettings, canvas: CGSize, stage: CGRect,
                            hasCamera: Bool) -> CameraFrame? {
        guard hasCamera, look.showsCamera else { return nil }
        if !look.showsScreen {
            let radius = CGFloat(edit.layout.cornerRadius) * min(stage.width, stage.height)
            return CameraFrame(rect: stage, cornerRadius: radius, borderWidth: 0, opacity: 1, fillsStage: true)
        }
        let style = edit.camera.with(look.placement)
        let rect = cameraRect(style: style, canvas: canvas)
        return CameraFrame(rect: rect, cornerRadius: style.shape.cornerRadius(for: rect.size),
                           borderWidth: CGFloat(style.borderWidth) * rect.height, opacity: 1, fillsStage: false)
    }

    /// Blends two camera states; appearing and disappearing cameras fade and scale.
    static func interpolate(_ from: CameraFrame?, _ to: CameraFrame?, _ progress: CGFloat) -> CameraFrame? {
        switch (from, to) {
        case (nil, nil):
            return nil
        case let (from?, to?):
            return CameraFrame(rect: lerp(from.rect, to.rect, progress),
                               cornerRadius: lerp(from.cornerRadius, to.cornerRadius, progress),
                               borderWidth: lerp(from.borderWidth, to.borderWidth, progress),
                               opacity: 1, fillsStage: progress < 0.5 ? from.fillsStage : to.fillsStage)
        case let (nil, to?):
            return scaled(to, by: lerp(0.8, 1, progress), opacity: progress)
        case let (from?, nil):
            return scaled(from, by: lerp(1, 0.8, progress), opacity: 1 - progress)
        }
    }

    private static func scaled(_ frame: CameraFrame, by scale: CGFloat, opacity: CGFloat) -> CameraFrame {
        var result = frame
        let size = CGSize(width: frame.rect.width * scale, height: frame.rect.height * scale)
        result.rect = CGRect(x: frame.rect.midX - size.width / 2, y: frame.rect.midY - size.height / 2,
                             width: size.width, height: size.height)
        result.cornerRadius *= scale
        result.borderWidth *= scale
        result.opacity = opacity
        return result
    }

    static func smoothstep(_ value: Double) -> Double {
        let t = value.clamped(to: 0...1)
        return t * t * (3 - 2 * t)
    }

    static func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }

    static func lerp(_ a: CGRect, _ b: CGRect, _ t: CGFloat) -> CGRect {
        CGRect(x: lerp(a.minX, b.minX, t), y: lerp(a.minY, b.minY, t),
               width: lerp(a.width, b.width, t), height: lerp(a.height, b.height, t))
    }

    static func cameraRect(style: CameraOverlayStyle, canvas: CGSize) -> CGRect {
        let minSide = min(canvas.width, canvas.height)
        let height = CGFloat(style.size) * minSide
        let width = height * style.shape.aspectRatio
        let margin = CGFloat(style.margin) * minSide
        let origin: CGPoint
        switch style.position {
        case .topLeft:
            origin = CGPoint(x: margin, y: margin)
        case .topRight:
            origin = CGPoint(x: canvas.width - margin - width, y: margin)
        case .bottomLeft:
            origin = CGPoint(x: margin, y: canvas.height - margin - height)
        case .bottomRight:
            origin = CGPoint(x: canvas.width - margin - width, y: canvas.height - margin - height)
        case .custom:
            origin = CGPoint(x: CGFloat(style.customX) * canvas.width - width / 2,
                             y: CGFloat(style.customY) * canvas.height - height / 2)
        }
        let x = origin.x.clamped(to: 0...max(0, canvas.width - width))
        let y = origin.y.clamped(to: 0...max(0, canvas.height - height))
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// The corner a placement is in (or closest to, for custom positions).
    static func corner(of placement: CameraPlacement) -> CameraPosition {
        guard placement.position == .custom else { return placement.position }
        switch (placement.customX < 0.5, placement.customY < 0.5) {
        case (true, true): return .topLeft
        case (false, true): return .topRight
        case (true, false): return .bottomLeft
        case (false, false): return .bottomRight
        }
    }

    /// The corner reached by moving the camera toward an edge, keeping the other axis.
    static func corner(of placement: CameraPlacement, movedToward edge: CameraEdge) -> CameraPosition {
        let current = corner(of: placement)
        let top = current == .topLeft || current == .topRight
        let left = current == .topLeft || current == .bottomLeft
        switch edge {
        case .left: return top ? .topLeft : .bottomLeft
        case .right: return top ? .topRight : .bottomRight
        case .top: return left ? .topLeft : .topRight
        case .bottom: return left ? .bottomLeft : .bottomRight
        }
    }

    /// The corner preset whose position is within snapping distance of `center` (normalized), if any.
    static func snappedCorner(for center: CGPoint, style: CameraOverlayStyle, canvas: CGSize) -> CameraPosition? {
        let threshold = min(canvas.width, canvas.height) * 0.06
        let point = CGPoint(x: center.x * canvas.width, y: center.y * canvas.height)
        for corner in CameraPosition.corners {
            var candidate = style
            candidate.position = corner
            let rect = cameraRect(style: candidate, canvas: canvas)
            if hypot(rect.midX - point.x, rect.midY - point.y) < threshold {
                return corner
            }
        }
        return nil
    }
}

enum CameraEdge {
    case left, right, top, bottom
}
