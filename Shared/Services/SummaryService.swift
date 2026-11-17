import Foundation

@MainActor
final class SummaryService: ObservableObject {
    static let shared = SummaryService()

    @Published private(set) var isRunning = false

    var isAIEnabled: Bool {
        AISettings.current.isConfigured
    }

    func summarize(memoID: UUID, force: Bool = false) async {
        guard var memo = MemoLibraryStore.shared.memo(id: memoID) else { return }
        let settings = AISettings.current
        guard settings.isConfigured else { return }
        if settings.manualOnly && !force { return }
        guard let transcript = memo.transcriptText, !transcript.isEmpty, memo.transcriptStatus == .completed else {
            return
        }

        isRunning = true
        memo.summaryStatus = .processing
        MemoLibraryStore.shared.save(memo)
        defer { isRunning = false }

        do {
            let text = try await OpenAICompatibleClient.summarize(transcript: transcript, settings: settings)
            memo.summaryStatus = .completed
            memo.summaryText = text
            MemoLibraryStore.shared.save(memo)
            AppLogger.ai.info("Summary completed \(memoID.uuidString, privacy: .public)")
        } catch {
            memo.summaryStatus = .failed
            memo.summaryText = "总结失败：\(error.localizedDescription)"
            MemoLibraryStore.shared.save(memo)
            AppLogger.ai.error("Summary failed: \(error.localizedDescription)")
        }
    }
}
