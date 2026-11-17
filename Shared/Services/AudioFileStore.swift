import Foundation

/// Resolves local vs iCloud Documents roots and audio file URLs.
/// Watch→iPhone ingest never depends on this path — that uses WatchConnectivity.
final class AudioFileStore: @unchecked Sendable {
    static let shared = AudioFileStore()

    private let fileManager = FileManager.default
    private let containerIdentifier = "iCloud.com.lytalk.TapNote"
    private var cachedRoot: URL?

    /// Prefer iCloud ubiquity container Documents; fall back to app Documents.
    var libraryRootURL: URL {
        if let cachedRoot { return cachedRoot }
        if let ubiquity = fileManager.url(forUbiquityContainerIdentifier: containerIdentifier) {
            let docs = ubiquity.appendingPathComponent("Documents", isDirectory: true)
            ensureDirectory(docs)
            ensureDirectory(docs.appendingPathComponent("audio", isDirectory: true))
            ensureDirectory(docs.appendingPathComponent("meta", isDirectory: true))
            cachedRoot = docs
            return docs
        }
        let local = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TapNoteLibrary", isDirectory: true)
        ensureDirectory(local)
        ensureDirectory(local.appendingPathComponent("audio", isDirectory: true))
        ensureDirectory(local.appendingPathComponent("meta", isDirectory: true))
        AppLogger.sync.warning("iCloud unavailable — using local Documents library")
        cachedRoot = local
        return local
    }

    var isUsingiCloud: Bool {
        fileManager.url(forUbiquityContainerIdentifier: containerIdentifier) != nil
    }

    /// Call after Apple ID / iCloud Drive sign-in so new recordings can move to ubiquity.
    func resetRootCache() {
        cachedRoot = nil
    }

    func audioURL(for memo: MemoRecording) -> URL {
        libraryRootURL.appendingPathComponent(memo.audioRelativePath)
    }

    func metadataURL(for id: UUID) -> URL {
        libraryRootURL
            .appendingPathComponent("meta", isDirectory: true)
            .appendingPathComponent("\(id.uuidString).json")
    }

    func temporaryRecordingURL(id: UUID) -> URL {
        let dir = fileManager.temporaryDirectory.appendingPathComponent("TapNoteRecordings", isDirectory: true)
        ensureDirectory(dir)
        return dir.appendingPathComponent("\(id.uuidString).m4a")
    }

    func ensureDirectory(_ url: URL) {
        if !fileManager.fileExists(atPath: url.path) {
            try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    func moveRecordingIntoLibrary(from tempURL: URL, memo: MemoRecording) throws -> URL {
        let dest = audioURL(for: memo)
        ensureDirectory(dest.deletingLastPathComponent())
        if fileManager.fileExists(atPath: dest.path) {
            try fileManager.removeItem(at: dest)
        }
        try fileManager.moveItem(at: tempURL, to: dest)
        return dest
    }
}
