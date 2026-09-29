import Foundation

/// Where the camera overlay sits, how big it is and its shape. Sections can override it.
struct CameraPlacement: Codable, Hashable {
    var position: CameraPosition = .bottomRight
    /// Normalized center (top-left origin) used when `position == .custom`.
    var customX: Double = 0.85
    var customY: Double = 0.8
    /// Overlay height as a fraction of the canvas' shorter side.
    var size: Double = 0.26
    /// nil uses the recording-wide shape (sections saved before shapes were per section).
    var shape: CameraShape?
}

/// A stretch of the recording between two splits. It ends where the next section starts.
/// Deleting a section only removes it from the edited video; the source files are untouched.
struct TimelineSection: Codable, Hashable, Identifiable {
    var id = UUID()
    /// Seconds from the start of the recording.
    var start: Double
    var isDeleted = false
    var showsScreen = true
    var showsCamera = true
    var mutesAudio = false
    /// nil uses the recording-wide placement from `CameraOverlayStyle`.
    var camera: CameraPlacement?

    init(start: Double) {
        self.start = start
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        start = try container.decodeIfPresent(Double.self, forKey: .start) ?? 0
        isDeleted = try container.decodeIfPresent(Bool.self, forKey: .isDeleted) ?? false
        showsScreen = try container.decodeIfPresent(Bool.self, forKey: .showsScreen) ?? true
        showsCamera = try container.decodeIfPresent(Bool.self, forKey: .showsCamera) ?? true
        mutesAudio = try container.decodeIfPresent(Bool.self, forKey: .mutesAudio) ?? false
        camera = try container.decodeIfPresent(CameraPlacement.self, forKey: .camera)
    }

    /// Whether the section changes anything besides being a separate piece.
    var isCustomized: Bool {
        isDeleted || !showsScreen || !showsCamera || mutesAudio || camera != nil
    }
}

extension CameraOverlayStyle {
    var placement: CameraPlacement {
        get { CameraPlacement(position: position, customX: customX, customY: customY, size: size, shape: shape) }
        set {
            position = newValue.position
            customX = newValue.customX
            customY = newValue.customY
            size = newValue.size
            shape = newValue.shape ?? shape
        }
    }

    func with(_ placement: CameraPlacement) -> CameraOverlayStyle {
        var style = self
        style.placement = placement
        return style
    }
}

// MARK: - Section queries and edits

extension EditSettings {
    /// Shortest section a split may create.
    static let minimumSectionLength = 0.1

    /// Index of the section playing at `time` (a split point belongs to the section it starts).
    func sectionIndex(at time: Double) -> Int {
        sections.lastIndex { $0.start <= time + 1e-6 } ?? 0
    }

    func section(at time: Double) -> TimelineSection {
        sections[sectionIndex(at: time)]
    }

    /// Recording-time range of a section. The last one ends at `duration`.
    func range(ofSectionAt index: Int, duration: Double) -> Range<Double> {
        let start = sections[index].start
        let end = index + 1 < sections.count ? sections[index + 1].start : max(start, duration)
        return start..<max(start, end)
    }

    /// The camera position, size and shape in a section (shape always filled in).
    func cameraPlacement(for section: TimelineSection) -> CameraPlacement {
        var placement = section.camera ?? camera.placement
        placement.shape = placement.shape ?? camera.shape
        return placement
    }

    /// The parts of the recording that make it into the video, in order and merged.
    /// - Parameter applyingTrim: Also cut away everything outside the trim handles.
    func keptRanges(duration: Double, applyingTrim: Bool) -> [Range<Double>] {
        let lower = applyingTrim ? trimStart : 0
        let upper = applyingTrim ? min(trimEnd ?? duration, duration) : duration
        var ranges: [Range<Double>] = []
        for index in sections.indices where !sections[index].isDeleted {
            let range = self.range(ofSectionAt: index, duration: duration).clamped(to: lower..<max(lower, upper))
            guard range.upperBound - range.lowerBound > 1e-6 else { continue }
            if let last = ranges.last, abs(last.upperBound - range.lowerBound) < 1e-6 {
                ranges[ranges.count - 1] = last.lowerBound..<range.upperBound
            } else {
                ranges.append(range)
            }
        }
        return ranges
    }

    /// Recording-time points where something changes: section starts plus the trim points.
    func editPoints(duration: Double) -> [Double] {
        var points = Set(sections.map(\.start))
        points.formUnion([0, duration, trimStart, trimEnd ?? duration])
        return points.filter { $0 >= 0 && $0 <= duration }.sorted()
    }

    /// Splits the section at `time`. Returns false when the split would create a sliver.
    @discardableResult
    mutating func split(at time: Double, duration: Double) -> Bool {
        let index = sectionIndex(at: time)
        let range = self.range(ofSectionAt: index, duration: duration)
        guard time - range.lowerBound >= Self.minimumSectionLength,
              range.upperBound - time >= Self.minimumSectionLength else { return false }
        var second = sections[index]
        second.id = UUID()
        second.start = time
        sections.insert(second, at: index + 1)
        return true
    }

    /// Removes the split between section `index` and the next one. The first section's
    /// settings apply to the joined section.
    @discardableResult
    mutating func joinSection(at index: Int) -> Bool {
        guard sections.indices.contains(index), index + 1 < sections.count else { return false }
        sections.remove(at: index + 1)
        return true
    }

    /// Repairs sections loaded from disk: sorted, starting at zero, never empty.
    mutating func normalizeSections() {
        sections.sort { $0.start < $1.start }
        var seen = Set<Double>()
        sections = sections.filter { seen.insert($0.start).inserted }
        if sections.isEmpty {
            sections = [TimelineSection(start: 0)]
        }
        sections[0].start = 0
    }
}

private extension Range where Bound == Double {
    func clamped(to limits: Range<Double>) -> Range<Double> {
        let lower = Swift.min(Swift.max(lowerBound, limits.lowerBound), limits.upperBound)
        let upper = Swift.min(Swift.max(upperBound, lower), limits.upperBound)
        return lower..<Swift.max(lower, upper)
    }
}

// MARK: - Timeline map

/// Maps between recording time and the edited video's timeline, where deleted and trimmed parts
/// are gone and the remaining pieces play back to back.
struct TimelineMap: Hashable, Sendable {
    struct Piece: Hashable, Sendable {
        var sourceStart: Double
        var sourceEnd: Double
        var outputStart: Double

        var duration: Double { sourceEnd - sourceStart }
        var outputEnd: Double { outputStart + duration }
    }

    let pieces: [Piece]

    /// - Parameter ranges: Sorted, non-overlapping recording-time ranges to keep.
    init(ranges: [Range<Double>]) {
        var output = 0.0
        var pieces: [Piece] = []
        for range in ranges where range.upperBound > range.lowerBound {
            pieces.append(Piece(sourceStart: range.lowerBound, sourceEnd: range.upperBound, outputStart: output))
            output += range.upperBound - range.lowerBound
        }
        self.pieces = pieces
    }

    init(pieces: [Piece]) {
        self.pieces = pieces
    }

    static func identity(duration: Double) -> TimelineMap {
        TimelineMap(ranges: [0..<max(duration, 0.001)])
    }

    var duration: Double { pieces.last?.outputEnd ?? 0 }

    /// Where recording time `time` plays in the edited video. Removed times map to the
    /// point where the video continues.
    func outputTime(forSource time: Double) -> Double {
        for piece in pieces {
            if time < piece.sourceStart { return piece.outputStart }
            if time < piece.sourceEnd { return piece.outputStart + (time - piece.sourceStart) }
        }
        return duration
    }

    /// Recording time shown at edited-video time `time`. At a cut, that's the start of the part
    /// after it, or with `preferringEarlier` the end of the part before it. The very end maps
    /// just inside the last part (not onto whatever was removed after it).
    func sourceTime(forOutput time: Double, preferringEarlier: Bool = false) -> Double {
        guard let last = pieces.last else { return time }
        let before = preferringEarlier ? pieces.first { abs($0.outputEnd - time) < 1e-6 } : nil
        if let piece = before ?? (time >= last.outputEnd - 1e-9 ? last : nil) {
            return max(piece.sourceStart, piece.sourceEnd - Self.endInset)
        }
        guard let piece = pieces.last(where: { $0.outputStart <= time + 1e-9 }) ?? pieces.first else { return time }
        return piece.sourceStart + min(max(0, time - piece.outputStart), piece.duration)
    }

    /// How far inside a part its end maps, so it's not mistaken for the next section.
    static let endInset = 0.001

    func contains(source time: Double) -> Bool {
        pieces.contains { time >= $0.sourceStart && time < $0.sourceEnd }
    }

    /// The edited-video ranges that show recording range `range`.
    func outputRanges(forSource range: Range<Double>) -> [Range<Double>] {
        var result: [Range<Double>] = []
        for piece in pieces {
            let lower = max(range.lowerBound, piece.sourceStart)
            let upper = min(range.upperBound, piece.sourceEnd)
            guard upper > lower else { continue }
            let output = (piece.outputStart + lower - piece.sourceStart)..<(piece.outputStart + upper - piece.sourceStart)
            if let last = result.last, abs(last.upperBound - output.lowerBound) < 1e-6 {
                result[result.count - 1] = last.lowerBound..<output.upperBound
            } else {
                result.append(output)
            }
        }
        return result
    }
}

extension Recording {
    /// The edited video's timeline: trimmed, with deleted sections removed.
    var editedTimeline: TimelineMap {
        TimelineMap(ranges: edit.keptRanges(duration: duration, applyingTrim: true))
    }

    var editedDuration: Double { editedTimeline.duration }
}
