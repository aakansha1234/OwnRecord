import CoreGraphics

/// Resolved geometry of one output frame. All rects use a top-left origin.
struct CanvasLayout: Equatable {
    var canvas: CGSize
    var screenRect: CGRect
    var screenCornerRadius: CGFloat
    var cameraRect: CGRect?
    var cameraCornerRadius: CGFloat
    var subtitleFontSize: CGFloat
    var subtitleMaxWidth: CGFloat
    /// Distance from the top/bottom canvas edge to the subtitle box.
    var subtitleMargin: CGFloat
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

    static func layout(canvas: CGSize, source: CGSize, edit: EditSettings, hasCamera: Bool) -> CanvasLayout {
        let minSide = min(canvas.width, canvas.height)
        let padding = CGFloat(edit.layout.padding) * minSide
        let available = CGRect(origin: .zero, size: canvas).insetBy(dx: padding, dy: padding)
        let screenRect = CGRect.aspectFit(source, in: available)
        let screenRadius = CGFloat(edit.layout.cornerRadius) * min(screenRect.width, screenRect.height)

        var cameraRect: CGRect?
        var cameraRadius: CGFloat = 0
        if hasCamera, edit.camera.isVisible {
            let rect = self.cameraRect(style: edit.camera, canvas: canvas)
            cameraRect = rect
            cameraRadius = edit.camera.shape.cornerRadius(for: rect.size)
        }

        let fontSize = max(8, CGFloat(edit.subtitles.fontScale) * minSide)
        let margin = canvas.height * 0.06
        var halfWidth = canvas.width * 0.42
        if let camera = cameraRect {
            // Keep subtitles clear of a camera overlay that shares their band.
            let bandHeight = fontSize * 2.8
            let band = edit.subtitles.position == .bottom
                ? CGRect(x: 0, y: canvas.height - margin - bandHeight, width: canvas.width, height: bandHeight)
                : CGRect(x: 0, y: margin, width: canvas.width, height: bandHeight)
            if camera.minY < band.maxY, camera.maxY > band.minY {
                let centerX = canvas.width / 2
                if camera.minX > centerX {
                    halfWidth = min(halfWidth, camera.minX - centerX - fontSize * 0.5)
                } else if camera.maxX < centerX {
                    halfWidth = min(halfWidth, centerX - camera.maxX - fontSize * 0.5)
                }
            }
        }
        halfWidth = max(halfWidth, canvas.width * 0.2)

        return CanvasLayout(canvas: canvas, screenRect: screenRect, screenCornerRadius: screenRadius,
                            cameraRect: cameraRect, cameraCornerRadius: cameraRadius,
                            subtitleFontSize: fontSize, subtitleMaxWidth: halfWidth * 2, subtitleMargin: margin)
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
