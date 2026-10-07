import CoreGraphics
import Foundation

/// The part of the screen recording the video shows, e.g. to leave out the menu bar and Dock or to
/// focus on one window. It applies to the whole video and comes before framing: the background,
/// padding, camera and subtitles are laid out around what's left. Like every edit it never touches
/// the recording, so the crop can be widened again at any time.
struct CropRect: Codable, Hashable {
    /// Normalized (0...1) with a top-left origin, like `Redaction`.
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    /// The whole recording.
    static let full = CropRect(rect: CGRect(x: 0, y: 0, width: 1, height: 1))
    /// Smallest side, as a fraction of the recording.
    static let minimumSide = 0.05

    init(rect: CGRect) {
        x = 0
        y = 0
        width = 1
        height = 1
        self.rect = rect
    }

    /// Kept inside the recording and never smaller than `minimumSide`.
    var rect: CGRect {
        get { CGRect(x: x, y: y, width: width, height: height) }
        set {
            width = Double(newValue.width).clamped(to: Self.minimumSide...1)
            height = Double(newValue.height).clamped(to: Self.minimumSide...1)
            x = Double(newValue.minX).clamped(to: 0...(1 - width))
            y = Double(newValue.minY).clamped(to: 0...(1 - height))
        }
    }

    /// Whether it keeps (practically) the whole recording.
    var isFull: Bool {
        x < 0.0005 && y < 0.0005 && width > 0.9995 && height > 0.9995
    }

    /// The crop in pixels of a frame of `size` (top-left origin), on whole pixels and with an even
    /// width and height as video encoders need, so the cropped screen fills its canvas exactly.
    func pixelRect(in size: CGSize) -> CGRect {
        guard size.width >= 2, size.height >= 2 else { return CGRect(origin: .zero, size: size) }
        func span(_ start: Double, _ length: Double, in total: CGFloat) -> (origin: CGFloat, length: CGFloat) {
            let largest = CGFloat(Int(total) & ~1)
            let length = min(max(2, CGFloat(Int((CGFloat(length) * total).rounded()) & ~1)), largest)
            return ((CGFloat(start) * total).rounded().clamped(to: 0...max(0, total - length)), length)
        }
        let horizontal = span(x, width, in: size.width)
        let vertical = span(y, height, in: size.height)
        return CGRect(x: horizontal.origin, y: vertical.origin, width: horizontal.length, height: vertical.length)
    }

    /// A crop from a rect in pixels of a recording of `size`.
    init(pixels rect: CGRect, in size: CGSize) {
        self.init(rect: CGRect(x: rect.minX / max(size.width, 1), y: rect.minY / max(size.height, 1),
                               width: rect.width / max(size.width, 1), height: rect.height / max(size.height, 1)))
    }
}

extension EditSettings {
    /// The part of a screen frame of `source` size that the video shows, in pixels (top-left origin).
    func screenCrop(in source: CGSize) -> CGRect {
        crop?.pixelRect(in: source) ?? CGRect(origin: .zero, size: source)
    }
}

// MARK: - Choosing a crop

/// Shapes the crop can be locked to while it's being chosen.
enum CropAspect: String, CaseIterable, Identifiable {
    case free, original, landscape, portrait, square, classic

    var id: String { rawValue }

    var title: String {
        switch self {
        case .free: "Freeform"
        case .original: "Original"
        case .landscape: "16:9"
        case .portrait: "9:16"
        case .square: "1:1"
        case .classic: "4:3"
        }
    }

    /// width / height in pixels for a recording of `source` size; nil for any shape.
    func ratio(source: CGSize) -> CGFloat? {
        switch self {
        case .free: nil
        case .original: source.aspectRatio
        case .landscape: AspectPreset.landscape.ratio
        case .portrait: AspectPreset.portrait.ratio
        case .square: AspectPreset.square.ratio
        case .classic: AspectPreset.classic.ratio
        }
    }

    /// The lock whose crops fill a video of this aspect ratio without bars (none for Auto, which
    /// follows the crop).
    init?(filling preset: AspectPreset) {
        switch preset {
        case .original: return nil
        case .landscape: self = .landscape
        case .portrait: self = .portrait
        case .square: self = .square
        case .classic: self = .classic
        }
    }
}

/// A handle of the crop being chosen: a corner or the middle of an edge.
enum CropHandle: CaseIterable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

    /// The vertical edge it moves: -1 the left one, 1 the right one, 0 neither.
    var horizontal: CGFloat {
        switch self {
        case .topLeft, .left, .bottomLeft: -1
        case .topRight, .right, .bottomRight: 1
        case .top, .bottom: 0
        }
    }

    /// The horizontal edge it moves: -1 the top one, 1 the bottom one, 0 neither.
    var vertical: CGFloat {
        switch self {
        case .topLeft, .top, .topRight: -1
        case .bottomLeft, .bottom, .bottomRight: 1
        case .left, .right: 0
        }
    }

    var isCorner: Bool { horizontal != 0 && vertical != 0 }
}

extension CropRect {
    /// `start` after dragging `handle` by `translation`, all in pixels of a recording of `size`.
    /// The result stays inside the recording and doesn't get smaller than `minimumSide`.
    /// - Parameters:
    ///   - ratio: The width / height to keep, or nil for any shape.
    ///   - fromCenter: Resize around the center instead of the opposite side (⌥, as in design apps).
    static func resizing(_ start: CGRect, handle: CropHandle, by translation: CGSize, in size: CGSize,
                         ratio: CGFloat?, fromCenter: Bool) -> CGRect {
        let h = handle.horizontal, v = handle.vertical
        let minimum = CGSize(width: size.width * minimumSide, height: size.height * minimumSide)
        // What stays put: the opposite corner or edge, or the center.
        let anchor = CGPoint(x: fromCenter || h == 0 ? start.midX : (h > 0 ? start.minX : start.maxX),
                             y: fromCenter || v == 0 ? start.midY : (v > 0 ? start.minY : start.maxY))

        /// The longest the crop can be along an axis without leaving the recording.
        func room(_ side: CGFloat, anchor: CGFloat, total: CGFloat) -> CGFloat {
            if fromCenter { return 2 * min(anchor, total - anchor) }
            if side > 0 { return total - anchor }
            if side < 0 { return anchor }
            // The axis the handle doesn't move: it may shift to make room (see `origin`).
            return total
        }
        let largest = CGSize(width: room(h, anchor: anchor.x, total: size.width),
                             height: room(v, anchor: anchor.y, total: size.height))

        // The size the pointer asks for on the axes the handle moves.
        let factor: CGFloat = fromCenter ? 2 : 1
        var width = h == 0 ? start.width : max(1, h * ((h > 0 ? start.maxX : start.minX) + translation.width - anchor.x) * factor)
        var height = v == 0 ? start.height : max(1, v * ((v > 0 ? start.maxY : start.minY) + translation.height - anchor.y) * factor)

        if let ratio, ratio > 0 {
            if handle.isCorner {
                // Corners follow whichever side the pointer pulls further.
                if width / height > ratio { height = width / ratio } else { width = height * ratio }
            } else if h != 0 {
                height = width / ratio
            } else {
                width = height * ratio
            }
            let shrink = min(1, largest.width / width, largest.height / height)
            width *= shrink
            height *= shrink
            let grow = max(1, minimum.width / width, minimum.height / height)
            if width * grow <= largest.width + 0.5, height * grow <= largest.height + 0.5 {
                width *= grow
                height *= grow
            }
        } else {
            width = width.clamped(to: min(minimum.width, largest.width)...largest.width)
            height = height.clamped(to: min(minimum.height, largest.height)...largest.height)
        }

        func origin(_ side: CGFloat, anchor: CGFloat, length: CGFloat, total: CGFloat) -> CGFloat {
            if fromCenter || side == 0 { return (anchor - length / 2).clamped(to: 0...max(0, total - length)) }
            return side > 0 ? anchor : anchor - length
        }
        return CGRect(x: origin(h, anchor: anchor.x, length: width, total: size.width),
                      y: origin(v, anchor: anchor.y, length: height, total: size.height),
                      width: width, height: height)
    }

    /// The largest rect of `ratio` (width / height) inside `rect`, centered on it; all in pixels of a
    /// recording of `size`. Used when a shape is chosen, so the crop keeps showing the same place.
    static func conforming(_ rect: CGRect, to ratio: CGFloat, in size: CGSize) -> CGRect {
        var fitted = CGRect.aspectFit(CGSize(width: ratio, height: 1), in: rect).size
        let grow = max(1, size.width * minimumSide / fitted.width, size.height * minimumSide / fitted.height)
        fitted = fitted.scaled(grow)
        fitted = fitted.scaled(min(1, size.width / fitted.width, size.height / fitted.height))
        return CGRect(x: (rect.midX - fitted.width / 2).clamped(to: 0...max(0, size.width - fitted.width)),
                      y: (rect.midY - fitted.height / 2).clamped(to: 0...max(0, size.height - fitted.height)),
                      width: fitted.width, height: fitted.height)
    }
}
