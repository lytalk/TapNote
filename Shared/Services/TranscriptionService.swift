import Foundation
#if canImport(Speech)
import Speech
#endif

@MainActor
final class TranscriptionService: ObservableObject {
    static let shared = TranscriptionService()

    @Published private(set) var isTranscribing = false

    #if canImport(Speech) && os(iOS)
    /// Chinese-friendly default; falls back to device locale.
    var preferredLocale: Locale {
        let zh = Locale(identifier: "zh-CN")
        if SFSpeechRecognizer(locale: zh) != nil {
            return zh
        }
        return Locale.current
    }

    func requestAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    func transcribe(memoID: UUID) async {
        guard var memo = MemoLibraryStore.shared.memo(id: memoID) else { return }
        isTranscribing = true
        memo.transcriptStatus = .processing
        MemoLibraryStore.shared.save(memo)

        defer { isTranscribing = false }

        // Missing usage description aborts the process — never call Speech without the key.
        guard Bundle.main.object(forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription") != nil else {
            memo.transcriptStatus = .failed
            memo.transcriptText = "缺少语音识别用途说明（NSSpeechRecognitionUsageDescription）。"
            MemoLibraryStore.shared.save(memo)
            AppLogger.speech.error("NSSpeechRecognitionUsageDescription missing — skip Speech")
            return
        }

        let auth = await requestAuthorization()
        guard auth == .authorized else {
            memo.transcriptStatus = .failed
            memo.transcriptText = "未授权语音识别，请在设置中开启。"
            MemoLibraryStore.shared.save(memo)
            return
        }

        guard let recognizer = SFSpeechRecognizer(locale: preferredLocale), recognizer.isAvailable else {
            memo.transcriptStatus = .failed
            memo.transcriptText = "当前设备无法使用语音识别。"
            MemoLibraryStore.shared.save(memo)
            return
        }

        let url = AudioFileStore.shared.audioURL(for: memo)
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        guard FileManager.default.fileExists(atPath: url.path) else {
            memo.transcriptStatus = .failed
            memo.transcriptText = "找不到音频文件，无法转写。"
            MemoLibraryStore.shared.save(memo)
            return
        }

        do {
            let text = try await recognize(url: url, recognizer: recognizer)
            memo.transcriptStatus = .completed
            memo.transcriptText = text
            MemoLibraryStore.shared.save(memo)
            AppLogger.speech.info("Transcribed \(memoID.uuidString, privacy: .public)")
        } catch {
            memo.transcriptStatus = .failed
            memo.transcriptText = "转写失败：\(error.localizedDescription)"
            MemoLibraryStore.shared.save(memo)
            AppLogger.speech.error("Transcription failed: \(error.localizedDescription)")
        }
    }

    private func recognize(url: URL, recognizer: SFSpeechRecognizer) async throws -> String {
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        request.requiresOnDeviceRecognition = false

        return try await withCheckedThrowingContinuation { continuation in
            var finished = false
            recognizer.recognitionTask(with: request) { result, error in
                guard !finished else { return }
                if let error {
                    finished = true
                    continuation.resume(throwing: error)
                    return
                }
                guard let result, result.isFinal else { return }
                finished = true
                continuation.resume(returning: result.bestTranscription.formattedString)
            }
        }
    }
    #else
    func transcribe(memoID: UUID) async {
        AppLogger.speech.warning("Speech unavailable on this platform; skip \(memoID.uuidString, privacy: .public)")
    }
    #endif
}
