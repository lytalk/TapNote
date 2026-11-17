import Foundation

/// File-level iCloud Documents sync.
/// On Simulator, ubiquity is usually nil until Settings → Apple ID → iCloud is signed in
/// and iCloud Drive is on. Watch→iPhone sync does **not** depend on iCloud — use WatchConnectivity.
@MainActor
final class ICloudDocumentSync: ObservableObject {
    static let shared = ICloudDocumentSync()

    @Published private(set) var isAvailable = false
    @Published private(set) var statusText = "检查 iCloud…"
    @Published private(set) var diagnosticDetail = ""

    private var query: NSMetadataQuery?
    private let files = AudioFileStore.shared
    private let containerIdentifier = "iCloud.com.lytalk.TapNote"

    func start() {
        refreshAvailability()
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name.NSUbiquityIdentityDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshAvailability()
            }
        }

        guard isAvailable else { return }

        let query = NSMetadataQuery()
        query.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        query.predicate = NSPredicate(
            format: "%K LIKE '*.json' OR %K LIKE '*.m4a'",
            NSMetadataItemFSNameKey,
            NSMetadataItemFSNameKey
        )
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

    func refreshAvailability() {
        let token = FileManager.default.ubiquityIdentityToken
        let url = FileManager.default.url(forUbiquityContainerIdentifier: containerIdentifier)
        isAvailable = (token != nil && url != nil)

        if isAvailable, let url {
            statusText = "iCloud Documents 已启用"
            diagnosticDetail = "容器 \(containerIdentifier)\n路径 \(url.path)"
            AppLogger.sync.info("iCloud available at \(url.path, privacy: .public)")
        } else if token == nil {
            statusText = "iCloud 未登录（使用本机库）"
            diagnosticDetail = """
            模拟器/设备未登录 Apple ID，或未打开 iCloud Drive。
            操作：打开「设置」→ 顶部 Apple ID 登录 → iCloud → 打开 iCloud 云盘。
            手表录音同步不依赖 iCloud，走 WatchConnectivity。
            容器标识：\(containerIdentifier)
            """
            AppLogger.sync.warning("iCloud unavailable — no ubiquityIdentityToken")
        } else {
            statusText = "iCloud 容器不可用（使用本机库）"
            diagnosticDetail = """
            已登录但拿不到容器 \(containerIdentifier)。
            请在 Xcode Signing & Capabilities 为 iOS/Watch 打开 iCloud → Cloud Documents，
            并确保 App ID 已开通同名 container。手表→手机仍走 WatchConnectivity。
            """
            AppLogger.sync.warning("iCloud token present but container URL nil")
        }

        // Re-resolve library root after identity changes; always keep a local fallback ready.
        files.resetRootCache()
        _ = files.libraryRootURL
    }

    @objc private func queryUpdated(_ note: Notification) {
        query?.disableUpdates()
        defer { query?.enableUpdates() }
        MemoLibraryStore.shared.reloadFromDisk()
        statusText = "已同步 \(MemoLibraryStore.shared.memos.count) 条"
    }
}
