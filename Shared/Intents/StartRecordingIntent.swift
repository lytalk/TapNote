import AppIntents
import Foundation

/// Action Button / Shortcuts / complication quick-start: opens TapNote and starts recording.
struct StartRecordingIntent: AppIntent {
    static var title: LocalizedStringResource = "开始录音"
    static var description = IntentDescription("立即打开 TapNote 并开始录音")
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        await MainActor.run {
            DeepLinkRouter.shared.markAutoRecord()
        }
        return .result()
    }
}

struct TapNoteShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartRecordingIntent(),
            phrases: [
                "用\(.applicationName)开始录音",
                "Start recording with \(.applicationName)",
                "\(.applicationName)录音"
            ],
            shortTitle: "开始录音",
            systemImageName: "mic.circle.fill"
        )
    }
}
