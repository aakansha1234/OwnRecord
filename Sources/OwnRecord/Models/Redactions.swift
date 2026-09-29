import CoreGraphics
import Foundation

enum RedactionStyle: String, Codable, CaseIterable, Identifiable {
    case blur, pixelate

    var id: String { rawValue }

    var title: String {
        switch self {
        case .blur: "Blur"
        case .pixelate: "Pixelate"
        }
    }

    /// Name of one area in this style, e.g. for undo: "Delete Pixelation".
    var noun: String {
        switch self {
        case .blur: "Blur"
        case .pixelate: "Pixelation"
        }
    }

    var symbol: String {
        switch self {
        case .blur: "drop.halffull"
        case .pixelate: "checkerboard.rectangle"
        }
    }
}

/// An area of the screen recording that's blurred or pixelated, e.g. to hide a password or email.
/// It belongs to a section, so it follows that section's splits like the other section settings.
struct Redaction: Codable, Hashable, Identifiable {
    var id = UUID()
    var style: RedactionStyle = .blur
    /// The area in the screen recording, normalized (0...1) with a top-left origin.
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    /// Smallest side, as a fraction of the recording, so an area stays visible and grabbable.
    static let minimumSide = 0.02

    init(style: RedactionStyle = .blur, rect: CGRect) {
        self.style = style
        x = 0
        y = 0
        width = 0
        height = 0
        self.rect = rect
    }

    /// Kept inside the recording and never smaller than `minimumSide`.
    var rect: CGRect {
        get { CGRect(x: x, y: y, width: width, height: height) }
        set {
            let side = Self.minimumSide
            width = Double(min(1, max(side, newValue.width)))
            height = Double(min(1, max(side, newValue.height)))
            x = Double(newValue.minX).clamped(to: 0...(1 - width))
            y = Double(newValue.minY).clamped(to: 0...(1 - height))
        }
    }

    /// The area in pixels of a frame of `size`, in Core Image's bottom-left-origin space.
    func pixelRect(in size: CGSize) -> CGRect {
        CGRect(x: x * size.width, y: (1 - y - height) * size.height,
               width: width * size.width, height: height * size.height).integral
    }
}
