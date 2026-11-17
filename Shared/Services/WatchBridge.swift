import Foundation
import WatchConnectivity

/// Transfers finished recordings Watch → iPhone via WatchConnectivity file transfer,
/// while both sides also write into the shared iCloud Documents library when available.
@MainActor
final class WatchBridge: NSObject, ObservableObject {
    static let shared = WatchBridge()

    @Published private(set) var isReachable = false
    @Published var lastTransferMessage: String?

    private var activated = false

    func activate() {
        guard WCSession.isSupported(), !activated else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
        activated = true
    }

    func sendMemoToPhone(_ memo: MemoRecording) {
        #if os(watchOS)
        guard WCSession.default.activationState == .activated else {
            lastTransferMessage = "WatchConnectivity 未激活，将依赖 iCloud"
            AppLogger.bridge.warning("WCSession not activated; relying on iCloud")
            return
        }
        let audioURL = AudioFileStore.shared.audioURL(for: memo)
        let metaURL = AudioFileStore.shared.metadataURL(for: memo.id)

        // Ensure metadata is on disk before transfer.
        MemoLibraryStore.shared.upsert(memo, preferIncomingIfNewer: false)

        if FileManager.default.fileExists(atPath: audioURL.path) {
            WCSession.default.transferFile(audioURL, metadata: [
                "memoID": memo.id.uuidString,
                "kind": "audio"
            ])
        }
        if FileManager.default.fileExists(atPath: metaURL.path) {
            WCSession.default.transferFile(metaURL, metadata: [
                "memoID": memo.id.uuidString,
                "kind": "meta"
            ])
        }
        lastTransferMessage = "已排队传到 iPhone"
        AppLogger.bridge.info("Queued transfer for \(memo.id.uuidString, privacy: .public)")
        #endif
    }
}

extension WatchBridge: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        Task { @MainActor in
            self.isReachable = session.isReachable
            if let error {
                AppLogger.bridge.error("Activation error: \(error.localizedDescription)")
            }
        }
    }

    #if os(iOS)
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }
    #endif

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in
            self.isReachable = session.isReachable
        }
    }

    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        Task { @MainActor in
            self.handleIncomingFile(file)
        }
    }

    @MainActor
    private func handleIncomingFile(_ file: WCSessionFile) {
        let kind = file.metadata?["kind"] as? String
        let idString = file.metadata?["memoID"] as? String
        guard let idString, let id = UUID(uuidString: idString) else {
            AppLogger.bridge.error("Incoming file missing memoID")
            return
        }

        let fm = FileManager.default
        do {
            if kind == "audio" {
                var memo = MemoLibraryStore.shared.memo(id: id) ?? MemoRecording(id: id, recordingStatus: .completed)
                let dest = AudioFileStore.shared.audioURL(for: memo)
                AudioFileStore.shared.ensureDirectory(dest.deletingLastPathComponent())
                if fm.fileExists(atPath: dest.path) {
                    try fm.removeItem(at: dest)
                }
                try fm.copyItem(at: file.fileURL, to: dest)
                memo.recordingStatus = .completed
                MemoLibraryStore.shared.upsert(memo, preferIncomingIfNewer: false)
                lastTransferMessage = "已接收 Watch 音频"
            } else {
                let data = try Data(contentsOf: file.fileURL)
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let memo = try decoder.decode(MemoRecording.self, from: data)
                MemoLibraryStore.shared.upsert(memo, preferIncomingIfNewer: true)
                lastTransferMessage = "已接收 Watch 元数据"
            }
            AppLogger.bridge.info("Ingested \(kind ?? "?") for \(id.uuidString, privacy: .public)")
        } catch {
            AppLogger.bridge.error("Ingest failed: \(error.localizedDescription)")
            lastTransferMessage = "接收失败：\(error.localizedDescription)"
        }
    }
}
