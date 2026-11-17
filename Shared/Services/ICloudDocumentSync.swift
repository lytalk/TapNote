import Foundation

/// File-level iCloud sync via ubiquity Documents container.
/// Choice (M2): **NSUbiquitousContainer file-level iCloud**, not CloudKit records.
/// Rationale: large audio blobs sync more simply as files; metadata is JSON sidecars;
/// conflict policy is last-writer-wins on `updatedAt` with os.Logger entries.
@MainActor
final class ICloudDocumentSync: ObservableObject {
    static let shared = ICloudDocumentSync()

    @Published private(set) var isAvailable = false
    @Published private(set) var statusText = "检查 iCloud…"

    private var query: NSMetadataQuery?
    private let files = AudioFileStore.shared

    func start() {
        isAvailable = files.isUsingiCloud
        statusText = isAvailable ? "iCloud Documents 已启用" : "iCloud 不可用，使用本机库"
        AppLogger.sync.info("iCloud available=\(self.isAvailable)")

        guard isAvailable else { return }

        let query = NSMetadataQuery()
        query.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        query.predicate = NSPredicate(format: "%K LIKE '*.json' OR %K LIKE '*.m4a'", NSMetadataItemFSNameKey, NSMetadataItemFSNameKey)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(queryUpdated(_:)),
            name: .NSMetadataQueryDidUpdate,
            object: query
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(queryUpdated(_:)),
            name: .NSMetadataQueryDidFinishGathering,
            object: query
        )
        query.start()
        self.query = query
    }

    @objc private func queryUpdated(_ note: Notification) {
        query?.disableUpdates()
        defer { query?.enableUpdates() }
        MemoLibraryStore.shared.reloadFromDisk()
        statusText = "已同步 \(MemoLibraryStore.shared.memos.count) 条"
    }
}
