import CoreGraphics
import Foundation

// MARK: - Layout

enum AspectPreset: String, Codable, CaseIterable, Identifiable {
    case original, landscape, portrait, square, classic

    var id: String { rawValue }

    var title: String {
        switch self {
        case .original: "Auto"
        case .landscape: "16:9"
        case .portrait: "9:16"
        case .square: "1:1"
        case .classic: "4:3"
        }
    }

    var detail: String {
        switch self {
        case .original: "Matches the recording"
        case .landscape: "YouTube, presentations"
        case .portrait: "Reels, TikTok, Shorts"
        case .square: "Social feeds"
        case .classic: "Classic"
        }
    }

    /// width / height, or nil to follow the source.
    var ratio: CGFloat? {
        switch self {
        case .original: nil
        case .landscape: 16.0 / 9.0
        case .portrait: 9.0 / 16.0
        case .square: 1
        case .classic: 4.0 / 3.0
        }
    }
}

enum BackgroundPreset: String, Codable, CaseIterable, Identifiable {
    case none, midnight, aurora, sunset, ocean, forest, peach, graphite, snow

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: "None"
        default: rawValue.capitalized
        }
    }

    /// Two gradient stops, top-left to bottom-right.
    var colors: [RGBAColor] {
        switch self {
        case .none: [.black, .black]
        case .midnight: [RGBAColor(hex: 0x0F172A), RGBAColor(hex: 0x3730A3)]
        case .aurora: [RGBAColor(hex: 0x7C3AED), RGBAColor(hex: 0x06B6D4)]
        case .sunset: [RGBAColor(hex: 0xF97316), RGBAColor(hex: 0xDB2777)]
        case .ocean: [RGBAColor(hex: 0x38BDF8), RGBAColor(hex: 0x1E3A8A)]
        case .forest: [RGBAColor(hex: 0x34D399), RGBAColor(hex: 0x065F46)]
        case .peach: [RGBAColor(hex: 0xFDA4AF), RGBAColor(hex: 0xFDE68A)]
        case .graphite: [RGBAColor(hex: 0x4B5563), RGBAColor(hex: 0x111827)]
        case .snow: [RGBAColor(hex: 0xF8FAFC), RGBAColor(hex: 0xCBD5E1)]
        }
    }
}

struct LayoutStyle: Codable, Hashable {
    var aspect: AspectPreset = .original
    var background: BackgroundPreset = .none
    /// Inset around the screen content, as a fraction of the canvas' shorter side.
    var padding: Double = 0
    /// Corner radius of the screen content, as a fraction of its shorter side.
    var cornerRadius: Double = 0
    /// Drop shadow strength behind the screen content (0...1). Only visible with padding.
    var shadow: Double = 0.6
}

// MARK: - Camera

enum CameraShape: String, Codable, CaseIterable, Identifiable {
    case circle, roundedSquare, roundedRectangle

    var id: String { rawValue }

    var title: String {
        switch self {
        case .circle: "Circle"
        case .roundedSquare: "Square"
        case .roundedRectangle: "Wide"
        }
    }

    var symbol: String {
        switch self {
        case .circle: "circle"
        case .roundedSquare: "square"
        case .roundedRectangle: "rectangle"
        }
    }

    /// width / height of the overlay.
    var aspectRatio: CGFloat {
        self == .roundedRectangle ? 16.0 / 9.0 : 1
    }

    func cornerRadius(for size: CGSize) -> CGFloat {
        let side = min(size.width, size.height)
        switch self {
        case .circle: return side / 2
        case .roundedSquare: return side * 0.22
        case .roundedRectangle: return side * 0.16
        }
    }
}

enum CameraPosition: String, Codable, CaseIterable, Identifiable {
    case topLeft, topRight, bottomLeft, bottomRight, custom

    var id: String { rawValue }

    static let corners: [CameraPosition] = [.topLeft, .topRight, .bottomLeft, .bottomRight]

    var title: String {
        switch self {
        case .topLeft: "Top Left"
        case .topRight: "Top Right"
        case .bottomLeft: "Bottom Left"
        case .bottomRight: "Bottom Right"
        case .custom: "Custom"
        }
    }
}

struct CameraOverlayStyle: Codable, Hashable {
    var isVisible = true
    var shape: CameraShape = .circle
    /// Overlay height as a fraction of the canvas' shorter side.
    var size: Double = 0.26
    var position: CameraPosition = .bottomRight
    /// Normalized center (top-left origin) used when `position == .custom`.
    var customX: Double = 0.85
    var customY: Double = 0.8
    /// Distance from the canvas edges, as a fraction of the canvas' shorter side.
    var margin: Double = 0.035
    /// Border thickness as a fraction of the overlay height.
    var borderWidth: Double = 0.025
    var borderColor: RGBAColor = .white
    var shadow = true
    var mirror = true
}

// MARK: - Subtitles

enum SubtitlePosition: String, Codable, CaseIterable, Identifiable {
    case bottom, top
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

struct SubtitleStyle: Codable, Hashable {
    /// Whether subtitles are rendered into the preview and burned into exports.
    var isEnabled = true
    /// Font size as a fraction of the canvas' shorter side.
    var fontScale: Double = 0.048
    var position: SubtitlePosition = .bottom
    var textColor: RGBAColor = .white
    var backgroundColor: RGBAColor = RGBAColor.black.withAlpha(0.62)
    var bold = true
}

// MARK: - Audio

struct AudioMixSettings: Codable, Hashable {
    var microphoneVolume: Double = 1
    var systemVolume: Double = 1
}

// MARK: - Edit

/// Every non-destructive edit applied to a recording. Source files are never modified.
struct EditSettings: Codable, Hashable {
    var trimStart: Double = 0
    /// nil means "until the end of the recording".
    var trimEnd: Double?
    var layout = LayoutStyle()
    var camera = CameraOverlayStyle()
    var subtitles = SubtitleStyle()
    var audio = AudioMixSettings()
}
