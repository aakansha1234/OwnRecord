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

/// The camera overlay's look. Visibility and placement can change per section (`TimelineSection`);
/// the placement here is the default, taken from where the bubble was during recording.
struct CameraOverlayStyle: Codable, Hashable {
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

/// How subtitles look. The recording has one style; sections can have their own (`TimelineSection`).
struct SubtitleStyle: Codable, Hashable {
    /// Whether subtitles are rendered into the preview and burned into exports.
    var isEnabled = true
    /// Font size as a fraction of the canvas' shorter side.
    var fontScale: Double = 0.048
    var position: SubtitlePosition = .bottom
    var textColor: RGBAColor = .white
    var backgroundColor: RGBAColor = RGBAColor.black.withAlpha(0.62)
    var bold = true
    /// Thickness of the outline around each letter, as a fraction of the font size. 0 for none.
    var outlineWidth: Double = 0
    var outlineColor: RGBAColor = .black
    /// A soft shadow behind the text when there's no background.
    var shadow = true
}

extension SubtitleStyle {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = SubtitleStyle()
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? defaults.isEnabled
        fontScale = try container.decodeIfPresent(Double.self, forKey: .fontScale) ?? defaults.fontScale
        position = try container.decodeIfPresent(SubtitlePosition.self, forKey: .position) ?? defaults.position
        textColor = try container.decodeIfPresent(RGBAColor.self, forKey: .textColor) ?? defaults.textColor
        backgroundColor = try container.decodeIfPresent(RGBAColor.self, forKey: .backgroundColor) ?? defaults.backgroundColor
        bold = try container.decodeIfPresent(Bool.self, forKey: .bold) ?? defaults.bold
        outlineWidth = try container.decodeIfPresent(Double.self, forKey: .outlineWidth) ?? defaults.outlineWidth
        outlineColor = try container.decodeIfPresent(RGBAColor.self, forKey: .outlineColor) ?? defaults.outlineColor
        shadow = try container.decodeIfPresent(Bool.self, forKey: .shadow) ?? defaults.shadow
    }
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
    /// Sorted by start; the first starts at 0. Never empty.
    var sections = [TimelineSection(start: 0)]
    var layout = LayoutStyle()
    var camera = CameraOverlayStyle()
    var subtitles = SubtitleStyle()
    var audio = AudioMixSettings()

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        trimStart = try container.decodeIfPresent(Double.self, forKey: .trimStart) ?? 0
        trimEnd = try container.decodeIfPresent(Double.self, forKey: .trimEnd)
        layout = try container.decodeIfPresent(LayoutStyle.self, forKey: .layout) ?? LayoutStyle()
        camera = try container.decodeIfPresent(CameraOverlayStyle.self, forKey: .camera) ?? CameraOverlayStyle()
        subtitles = try container.decodeIfPresent(SubtitleStyle.self, forKey: .subtitles) ?? SubtitleStyle()
        audio = try container.decodeIfPresent(AudioMixSettings.self, forKey: .audio) ?? AudioMixSettings()
        if let sections = try container.decodeIfPresent([TimelineSection].self, forKey: .sections) {
            self.sections = sections
        } else {
            // Recordings edited before sections existed had one camera switch for the whole video.
            let legacy = try container.decodeIfPresent(LegacyCameraVisibility.self, forKey: .camera)
            sections[0].showsCamera = legacy?.isVisible ?? true
        }
        normalizeSections()
    }

    private struct LegacyCameraVisibility: Decodable {
        var isVisible: Bool?
    }
}
