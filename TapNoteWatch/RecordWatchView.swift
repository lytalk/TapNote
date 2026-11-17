import SwiftUI

struct RecordWatchView: View {
    @EnvironmentObject private var library: MemoLibraryStore
    @EnvironmentObject private var bridge: WatchBridge
    @StateObject private var session = RecordingSession()
    @State private var errorText: String?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Text(Formatters.durationString(session.elapsed))
                    .font(.title2.monospacedDigit())

                Button {
                    Task { await toggle() }
                } label: {
                    Image(systemName: session.isRecording ? "stop.circle.fill" : "mic.circle.fill")
                        .font(.system(size: 64))
                        .foregroundStyle(session.isRecording ? .red : .accentColor)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(session.isRecording ? "停止" : "录音")

                Text(session.isRecording ? "录音中" : "轻点录音")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                if let errorText {
                    Text(errorText)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }

                NavigationLink("资料库") {
                    WatchLibraryView()
                }
                .font(.caption)
            }
            .navigationTitle("TapNote")
            .onChange(of: scenePhase) { _, phase in
                // Best-effort: keep session category active; watchOS may suspend mic when inactive.
                if phase == .background, session.isRecording {
                    AppLogger.record.info("Entered background while recording")
                }
            }
        }
    }

    private func toggle() async {
        errorText = nil
        do {
            if session.isRecording {
                let (memo, _) = try await session.stop()
                library.upsert(memo, preferIncomingIfNewer: false)
                bridge.sendMemoToPhone(memo)
            } else {
                // Prefer extended runtime session style habits: activate audio session before record.
                _ = try await session.start()
            }
        } catch {
            errorText = error.localizedDescription
        }
    }
}
