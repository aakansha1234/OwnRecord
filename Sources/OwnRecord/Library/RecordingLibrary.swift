import AppKit
import Foundation
import Observation

/// All recordings on disk. Each recording lives in its own folder under `rootURL`.
@MainActor @Observable
final class RecordingLibrary {
    private(set) var recordings: [Recording] = []
    /// Bumped whenever a thumbnail is rewritten so views reload it.
    private(set) var thumbnailRevision: [UUID: Int] = [:]

    let rootURL: URL
    @ObservationIgnored private var folders: [UUID: URL] = [:]

    nonisolated static var defaultRoot: URL {
        FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OwnRecord", isDirectory: true)
    }

    init(rootURL: URL = RecordingLibrary.defaultRoot) {
        self.rootURL = rootURL
        try? FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        reload()
    }

    func reload() {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: rootURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        var loaded: [Recording] = []
        var map: [UUID: URL] = [:]
        for folder in items {
            let files = RecordingFiles(folder: folder)
            guard let data = try? Data(contentsOf: files.metadata),
                  let recording = try? Self.decoder.decode(Recording.self, from: data) else { continue }
            loaded.append(recording)
            map[recording.id] = folder
        }
        recordings = loaded.sorted { $0.createdAt > $1.createdAt }
        folders = map
    }

    func recording(with id: UUID) -> Recording? {
        recordings.first { $0.id == id }
    }

    func files(for id: UUID) -> RecordingFiles? {
        folders[id].map(RecordingFiles.init(folder:))
    }

    /// Creates an empty, uniquely named folder for a new recording.
    func makeRecordingFolder(date: Date = Date()) throws -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let base = "Recording \(formatter.string(from: date))"
        var url = rootURL.appendingPathComponent(base, isDirectory: true)
        var suffix = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = rootURL.appendingPathComponent("\(base) \(suffix)", isDirectory: true)
            suffix += 1
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func save(_ recording: Recording, in folder: URL? = nil) {
        guard let folder = folder ?? folders[recording.id] else { return }
        folders[recording.id] = folder
        do {
            let data = try Self.encoder.encode(recording)
            try data.write(to: RecordingFiles(folder: folder).metadata, options: .atomic)
        } catch {
            NSLog("OwnRecord: failed to save recording metadata: \(error)")
        }
        if let index = recordings.firstIndex(where: { $0.id == recording.id }) {
            recordings[index] = recording
        } else {
            recordings.insert(recording, at: 0)
            recordings.sort { $0.createdAt > $1.createdAt }
        }
    }

    func rename(_ id: UUID, to title: String) {
        guard var recording = recording(with: id) else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        recording.title = trimmed
        save(recording)
    }

    func delete(_ id: UUID) {
        if let folder = folders[id] {
            try? FileManager.default.trashItem(at: folder, resultingItemURL: nil)
        }
        folders[id] = nil
        recordings.removeAll { $0.id == id }
    }

    func revealInFinder(_ id: UUID) {
        guard let files = files(for: id) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([files.screen])
    }

    func thumbnailDidChange(_ id: UUID) {
        thumbnailRevision[id, default: 0] += 1
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
