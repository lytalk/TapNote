import Foundation

@MainActor
final class MemoLibraryStore: ObservableObject {
    static let shared = MemoLibraryStore()

    @Published private(set) var memos: [MemoRecording] = []
    @Published private(set) var lastSyncMessage: String?

    private let files = AudioFileStore.shared
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private var ubiquityObserver: NSObjectProtocol?

    init() {
        reloadFromDisk()
        startObservingiCloud()
    }

    deinit {
        if let ubiquityObserver {
            NotificationCenter.default.removeObserver(ubiquityObserver)
        }
    }

    func reloadFromDisk() {
        let metaDir = files.libraryRootURL.appendingPathComponent("meta", isDirectory: true)
        files.ensureDirectory(metaDir)
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: metaDir,
            includingPropertiesForKeys: nil
        ) else {
            memos = []
            return
        }

        var loaded: [MemoRecording] = []
        for url in urls where url.pathExtension == "json" {
            do {
                // Start downloading ubiquitous items if needed.
                try? FileManager.default.startDownloadingUbiquitousItem(at: url)
                let data = try Data(contentsOf: url)
                let memo = try decoder.decode(MemoRecording.self, from: data)
                loaded.append(memo)
            } catch {
                AppLogger.sync.error("Failed to decode \(url.lastPathComponent, privacy: .public): \(error.localizedDescription)")
            }
        }
        memos = loaded.sorted { $0.createdAt > $1.createdAt }
    }

    func upsert(_ memo: MemoRecording, preferIncomingIfNewer: Bool = true) {
        if let index = memos.firstIndex(where: { $0.id == memo.id }) {
            let existing = memos[index]
            if preferIncomingIfNewer, memo.updatedAt < existing.updatedAt {
                AppLogger.sync.info(
                    "Conflict LWW keep local id=\(memo.id.uuidString, privacy: .public) local=\(existing.updatedAt.timeIntervalSince1970) incoming=\(memo.updatedAt.timeIntervalSince1970)"
                )
                lastSyncMessage = "冲突：保留较新本地版本 \(memo.title)"
                return
            }
            if preferIncomingIfNewer, memo.updatedAt > existing.updatedAt {
                AppLogger.sync.info(
                    "Conflict LWW accept incoming id=\(memo.id.uuidString, privacy: .public)"
                )
                lastSyncMessage = "冲突：采用较新云端版本 \(memo.title)"
            }
            memos[index] = memo
        } else {
            memos.insert(memo, at: 0)
        }
        memos.sort { $0.createdAt > $1.createdAt }
        persist(memo)
    }

    func save(_ memo: MemoRecording) {
        var copy = memo
        copy.touch()
        upsert(copy, preferIncomingIfNewer: false)
    }

    func rename(id: UUID, title: String) {
        guard var memo = memos.first(where: { $0.id == id }) else { return }
        memo.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if memo.title.isEmpty {
            memo.title = MemoRecording.defaultTitle(for: memo.createdAt)
        }
        save(memo)
    }

    func delete(id: UUID) {
        guard let memo = memos.first(where: { $0.id == id }) else { return }
        memos.removeAll { $0.id == id }
        let meta = files.metadataURL(for: id)
        let audio = files.audioURL(for: memo)
        try? FileManager.default.removeItem(at: meta)
        try? FileManager.default.removeItem(at: audio)
        AppLogger.sync.info("Deleted memo \(id.uuidString, privacy: .public)")
    }

    func memo(id: UUID) -> MemoRecording? {
        memos.first { $0.id == id }
    }

    private func persist(_ memo: MemoRecording) {
        let url = files.metadataURL(for: memo.id)
        do {
            let data = try encoder.encode(memo)
            try data.write(to: url, options: [.atomic])
        } catch {
            AppLogger.sync.error("Persist failed: \(error.localizedDescription)")
        }
    }

    private func startObservingiCloud() {
        ubiquityObserver = NotificationCenter.default.addObserver(
            forName: .NSMetadataQueryDidUpdate,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.reloadFromDisk()
            }
        }

        // Also poll lightly when returning to foreground paths.
        Timer.scheduledTimer(withTimeInterval: 8, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.reloadFromDisk()
            }
        }
    }
}
