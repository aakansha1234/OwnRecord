import AppKit
import CoreImage
import CoreText

/// Renders subtitle text into images (cached, since a cue spans many frames).
final class SubtitleRenderer: @unchecked Sendable {
    static let shared = SubtitleRenderer()

    private let cache = NSCache<NSString, CIImage>()

    init() {
        cache.countLimit = 64
    }

    func image(text: String, style: SubtitleStyle, fontSize: CGFloat, maxWidth: CGFloat) -> CIImage? {
        let key = "\(text)|\(style.hashValue)|\(Int(fontSize * 10))|\(Int(maxWidth))" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let cgImage = Self.render(text: text, style: style, fontSize: fontSize, maxWidth: maxWidth) else { return nil }
        let image = CIImage(cgImage: cgImage)
        cache.setObject(image, forKey: key)
        return image
    }

    static func render(text: String, style: SubtitleStyle, fontSize: CGFloat, maxWidth: CGFloat) -> CGImage? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, fontSize > 0 else { return nil }

        let font = NSFont.systemFont(ofSize: fontSize, weight: style.bold ? .bold : .medium)
        var alignment = CTTextAlignment.center
        let paragraph = withUnsafeBytes(of: &alignment) { pointer -> CTParagraphStyle in
            var setting = CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size,
                                                  value: pointer.baseAddress!)
            return CTParagraphStyleCreate(&setting, 1)
        }
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): style.textColor.cgColor,
            NSAttributedString.Key(kCTParagraphStyleAttributeName as String): paragraph,
        ]
        let attributed = NSAttributedString(string: trimmed, attributes: attributes)

        let horizontalPadding = fontSize * 0.55
        let verticalPadding = fontSize * 0.28
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let constraint = CGSize(width: max(fontSize * 4, maxWidth - horizontalPadding * 2), height: .greatestFiniteMagnitude)
        let fit = CTFramesetterSuggestFrameSizeWithConstraints(framesetter, CFRange(location: 0, length: 0), nil, constraint, nil)
        let textSize = CGSize(width: ceil(fit.width) + 2, height: ceil(fit.height))
        let size = CGSize(width: textSize.width + horizontalPadding * 2, height: textSize.height + verticalPadding * 2)

        guard let context = CGContext(data: nil, width: Int(ceil(size.width)), height: Int(ceil(size.height)),
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }

        let bounds = CGRect(origin: .zero, size: size)
        if style.backgroundColor.alpha > 0.01 {
            let radius = fontSize * 0.32
            context.addPath(CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil))
            context.setFillColor(style.backgroundColor.cgColor)
            context.fillPath()
        } else if style.shadow {
            // No box: add a soft shadow so text stays legible on any background.
            context.setShadow(offset: CGSize(width: 0, height: -fontSize * 0.04), blur: fontSize * 0.25,
                              color: CGColor(gray: 0, alpha: 0.85))
        }

        let path = CGPath(rect: CGRect(x: horizontalPadding, y: verticalPadding, width: textSize.width, height: textSize.height),
                          transform: nil)
        if style.outlineWidth > 0 {
            // Stroke the letters first, twice as wide as the outline since half the stroke lies
            // inside them, then fill on top. (A stroke width is a percentage of the font size.)
            var outlined = attributes
            outlined[NSAttributedString.Key(kCTStrokeWidthAttributeName as String)] = style.outlineWidth * 200
            outlined[NSAttributedString.Key(kCTStrokeColorAttributeName as String)] = style.outlineColor.cgColor
            let outline = CTFramesetterCreateWithAttributedString(NSAttributedString(string: trimmed, attributes: outlined))
            context.setLineJoin(.round)
            CTFrameDraw(CTFramesetterCreateFrame(outline, CFRange(location: 0, length: 0), path, nil), context)
            // The outline already casts the shadow.
            context.setShadow(offset: .zero, blur: 0, color: nil)
        }
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
        CTFrameDraw(frame, context)
        return context.makeImage()
    }
}
