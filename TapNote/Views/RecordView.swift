import SwiftUI

struct RecordView: View {
    @EnvironmentObject private var library: MemoLibraryStore
    @EnvironmentObject private var bridge: WatchBridge
    @StateObject private var session = RecordingSession()
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 28) {
                Spacer()
                Text(Formatters.durationString(session.elapsed))
                    .font(.system(size: 48, weight: .light, design: .rounded))
                    .monospacedDigit()

                Button {
                    Task { await toggle() }
                } label: {
                    Image(systemName: session.isRecording ? "stop.circle.fill" : "mic.circle.fill")
                        .font(.system(size: 96))
                        .foregroundStyle(session.isRecording ? Color.red : Color.accentColor)
                }
                .accessibilityLabel(session.isRecording ? "停止录音" : "开始录音")

                Text(session.isRecording ? "录音中…" : "轻点开始")
                    .foregroundStyle(.secondary)

                if let errorText {
                    Text(errorText)
                        .foregroundStyle(.red)
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                Spacer()
            }
            .navigationTitle("录音")
        }
    }

    private func toggle() async {
        errorText = nil
        do {
            if session.isRecording {
                let (memo, _) = try await session.stop()
                library.upsert(memo, preferIncomingIfNewer: false)
                await TranscriptionService.shared.transcribe(memoID: memo.id)
            } else {
                _ = try await session.start()
            }
        } catch {
            errorText = error.localizedDescription
        }
    }
}
