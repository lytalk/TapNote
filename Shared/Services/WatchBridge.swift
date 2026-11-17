import AVFoundation
import Foundation
import WatchConnectivity

/// Watch → iPhone ingest via WatchConnectivity.
/// Strategy: when reachable, send memo JSON + audio bytes immediately via `sendMessage`;
/// always also queue `transferUserInfo` (meta) + `transferFile` (audio) for reliability.
@MainActor
final class WatchBridge: NSObject, ObservableObject {
    static let shared = WatchBridge()

    @Published private(set) var isReachable = false
    @Published private(set) var activationState: WCSessionActivationState = .notActivated
    @Published var lastTransferMessage: String?

    private var activated = false

    func activate() {
        guard WCSession.isSupported() else {
            lastTransferMessage = "此设备不支持 WatchConnectivity"
            return
        }
        let session = WCSession.default
        session.delegate = self
        if !activated {
            session.activate()
            activated = true
        }
    }

    func sendMemoToPhone(_ memo: MemoRecording) {
        #if os(watchOS)
        activate()
        MemoLibraryStore.shared.upsert(memo, preferIncomingIfNewer: false)

        let audioURL = AudioFileStore.shared.audioURL(for: memo)
        let metaURL = AudioFileStore.shared.metadataURL(for: memo.id)
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            lastTransferMessage = "音频文件不存在，无法同步"
            AppLogger.bridge.error("Missing audio for transfer \(memo.id.uuidString, privacy: .public)")
            return
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let metaData = try? encoder.encode(memo),
              let metaJSON = String(data: metaData, encoding: .utf8) else {
            lastTransferMessage = "元数据编码失败"
            return
        }

        let session = WCSession.default
        // 1) Queued userInfo — delivered even if phone app is suspended.
        session.transferUserInfo([
            "kind": "meta",
            "memoID": memo.id.uuidString,
            "metaJSON": metaJSON
        ])

        // 2) Queued file transfer for audio.
        session.transferFile(audioURL, metadata: [
            "memoID": memo.id.uuidString,
            "kind": "audio"
        ])
        if FileManager.default.fileExists(atPath: metaURL.path) {
            session.transferFile(metaURL, metadata: [
                "memoID": memo.id.uuidString,
                "kind": "meta"
            ])
        }

        // 3) Immediate path when reachable (critical for Simulator pairing).
        if session.activationState == .activated, session.isReachable,
           let audioData = try? Data(contentsOf: audioURL) {
            // Keep payloads reasonable for sendMessage (~few MB ok for short memos).
            let payload: [String: Any] = [
                "kind": "memoBundle",
                "memoID": memo.id.uuidString,
                "metaJSON": metaJSON,
                "audioBase64": audioData.base64EncodedString()
            ]
            session.sendMessage(payload, replyHandler: { reply in
                Task { @MainActor in
                    let ok = reply["ok"] as? Bool ?? false
                    self.lastTransferMessage = ok ? "已实时同步到 iPhone" : "iPhone 回复失败"
                    AppLogger.bridge.info("sendMessage reply ok=\(ok)")
                }
            }, errorHandler: { error in
                Task { @MainActor in
                    self.lastTransferMessage = "实时同步失败，已改排队：\(error.localizedDescription)"
                    AppLogger.bridge.error("sendMessage failed: \(error.localizedDescription)")
                }
            })
            lastTransferMessage = "正在实时同步到 iPhone…"
        } else {
            lastTransferMessage = "已排队同步到 iPhone（手机需打开 TapNote）"
        }

        AppLogger.bridge.info(
            "Queued/sent transfer id=\(memo.id.uuidString, privacy: .public) reachable=\(session.isReachable) state=\(session.activationState.rawValue)"
        )
        #endif
    }

    #if os(iOS)
    @MainActor
    func ingestMetaJSON(_ metaJSON: String) throws -> MemoRecording {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = metaJSON.data(using: .utf8) else {
            throw BridgeError.badPayload
        }
        let memo = try decoder.decode(MemoRecording.self, from: data)
        MemoLibraryStore.shared.upsert(memo, preferIncomingIfNewer: true)
        return memo
    }

    @MainActor
    func ingestAudio(memoID: UUID, from sourceURL: URL) throws {
        var memo = MemoLibraryStore.shared.memo(id: memoID)
            ?? MemoRecording(id: memoID, recordingStatus: .completed, sourceDevice: "Apple Watch")
        let dest = AudioFileStore.shared.audioURL(for: memo)
        AudioFileStore.shared.ensureDirectory(dest.deletingLastPathComponent())
        let fm = FileManager.default
        if fm.fileExists(atPath: dest.path) {
            try fm.removeItem(at: dest)
        }
        try fm.copyItem(at: sourceURL, to: dest)
        try Self.validateAudioFile(at: dest)
        memo.recordingStatus = .completed
        if memo.sourceDevice.isEmpty { memo.sourceDevice = "Apple Watch" }
        // Prefer actual duration from file if meta was incomplete.
        if memo.duration < 0.05, let dur = Self.audioDuration(at: dest) {
            memo.duration = dur
        }
        MemoLibraryStore.shared.upsert(memo, preferIncomingIfNewer: false)
        Task { await TranscriptionService.shared.transcribe(memoID: memoID) }
    }

    @MainActor
    func ingestBundle(metaJSON: String, audioBase64: String) throws {
        let memo = try ingestMetaJSON(metaJSON)
        guard let audioData = Data(base64Encoded: audioBase64), !audioData.isEmpty else {
            throw BridgeError.badPayload
        }
        let dest = AudioFileStore.shared.audioURL(for: memo)
        AudioFileStore.shared.ensureDirectory(dest.deletingLastPathComponent())
        try audioData.write(to: dest, options: .atomic)
        try Self.validateAudioFile(at: dest)
        var updated = memo
        updated.recordingStatus = .completed
        if updated.duration < 0.05, let dur = Self.audioDuration(at: dest) {
            updated.duration = dur
        }
        MemoLibraryStore.shared.upsert(updated, preferIncomingIfNewer: false)
        Task { await TranscriptionService.shared.transcribe(memoID: memo.id) }
        lastTransferMessage = "已接收手表录音 \(memo.title)"
        AppLogger.bridge.info("Ingested bundle \(memo.id.uuidString, privacy: .public) bytes=\(audioData.count)")
    }

    private static func validateAudioFile(at url: URL) throws {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
        guard size > 0 else { throw BridgeError.corruptAudio }
        // Ensure AVFoundation can open it (guards truncated WC payloads).
        _ = try AVAudioFile(forReading: url)
    }

    private static func audioDuration(at url: URL) -> TimeInterval? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let frames = Double(file.length)
        let rate = file.processingFormat.sampleRate
        guard rate > 0 else { return nil }
        return frames / rate
    }
    #endif
}

enum BridgeError: LocalizedError {
    case badPayload
    case corruptAudio
    var errorDescription: String? {
        switch self {
        case .badPayload: return "同步数据无效"
        case .corruptAudio: return "手表音频损坏或不完整"
        }
    }
}

extension WatchBridge: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        Task { @MainActor in
            self.activationState = activationState
            self.isReachable = session.isReachable
            if let error {
                AppLogger.bridge.error("Activation error: \(error.localizedDescription)")
            } else {
                AppLogger.bridge.info("WCSession activated state=\(activationState.rawValue)")
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

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        Task { @MainActor in
            #if os(iOS)
            if let json = userInfo["metaJSON"] as? String {
                do {
                    let memo = try self.ingestMetaJSON(json)
                    self.lastTransferMessage = "已收手表元数据 \(memo.title)"
                } catch {
                    AppLogger.bridge.error("userInfo meta failed: \(error.localizedDescription)")
                }
            }
            #endif
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        Task { @MainActor in
            #if os(iOS)
            do {
                if message["kind"] as? String == "memoBundle",
                   let metaJSON = message["metaJSON"] as? String,
                   let audioBase64 = message["audioBase64"] as? String {
                    try self.ingestBundle(metaJSON: metaJSON, audioBase64: audioBase64)
                    replyHandler(["ok": true])
                    return
                }
                replyHandler(["ok": false, "error": "unknown"])
            } catch {
                AppLogger.bridge.error("message ingest failed: \(error.localizedDescription)")
                replyHandler(["ok": false, "error": error.localizedDescription])
            }
            #else
            replyHandler(["ok": false])
            #endif
        }
    }

    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        Task { @MainActor in
            #if os(iOS)
            let kind = file.metadata?["kind"] as? String
            let idString = file.metadata?["memoID"] as? String
            guard let idString, let id = UUID(uuidString: idString) else {
                AppLogger.bridge.error("Incoming file missing memoID")
                return
            }
            do {
                if kind == "audio" {
                    try self.ingestAudio(memoID: id, from: file.fileURL)
                    self.lastTransferMessage = "已接收手表音频"
                } else if kind == "meta" {
                    let data = try Data(contentsOf: file.fileURL)
                    let decoder = JSONDecoder()
                    decoder.dateDecodingStrategy = .iso8601
                    let memo = try decoder.decode(MemoRecording.self, from: data)
                    MemoLibraryStore.shared.upsert(memo, preferIncomingIfNewer: true)
                    self.lastTransferMessage = "已接收手表元数据"
                }
                AppLogger.bridge.info("File ingest \(kind ?? "?") \(id.uuidString, privacy: .public)")
            } catch {
                AppLogger.bridge.error("File ingest failed: \(error.localizedDescription)")
                self.lastTransferMessage = "接收失败：\(error.localizedDescription)"
            }
            #endif
        }
    }
}
