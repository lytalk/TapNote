import SwiftUI

struct MemoDetailView: View {
    let memoID: UUID

    @EnvironmentObject private var library: MemoLibraryStore
    @EnvironmentObject private var player: AudioPlayerService
    @StateObject private var transcription = TranscriptionService.shared
    @State private var showTrim = false
    @State private var shareItems: [Any] = []
    @State private var showShare = false

    private var memo: MemoRecording? { library.memo(id: memoID) }

    var body: some View {
        Group {
            if let memo {
                content(memo)
            } else {
                ContentUnavailableView("录音不存在", systemImage: "questionmark.folder")
            }
        }
    }

    @ViewBuilder
    private func content(_ memo: MemoRecording) -> some View {
        List {
            Section("播放") {
                HStack {
                    Button {
                        togglePlay(memo)
                    } label: {
                        Image(systemName: player.isPlaying && player.playingID == memo.id ? "pause.fill" : "play.fill")
                            .font(.title2)
                    }
                    .buttonStyle(.borderless)

                    VStack(alignment: .leading) {
                        Text(memo.title).font(.headline)
                        Text("\(Formatters.durationString(player.playingID == memo.id ? player.currentTime : 0)) / \(Formatters.durationString(memo.duration))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text("来源：\(memo.sourceDevice)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Section("文稿（系统 Speech）") {
                if let text = memo.transcriptText, memo.transcriptStatus == .completed {
                    Text(text)
                        .textSelection(.enabled)
                } else if memo.transcriptStatus == .processing || transcription.isTranscribing {
                    ProgressView("转写中…")
                } else if memo.transcriptStatus == .failed {
                    Text(memo.transcriptText ?? "转写失败")
                        .foregroundStyle(.red)
                } else {
                    Text("尚未转写")
                        .foregroundStyle(.secondary)
                }
                Button("转写 / 重试") {
                    Task { await transcription.transcribe(memoID: memo.id) }
                }
                .disabled(transcription.isTranscribing)
            }

            Section("操作") {
                Button("裁剪首尾") { showTrim = true }
                Button("分享音频") {
                    let url = AudioFileStore.shared.audioURL(for: memo)
                    shareItems = [url]
                    showShare = true
                }
                if let text = memo.transcriptText, !text.isEmpty {
                    Button("分享文稿") {
                        shareItems = [text]
                        showShare = true
                    }
                }
            }
        }
        .navigationTitle(memo.title)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showTrim) {
            TrimView(memoID: memo.id)
        }
        .sheet(isPresented: $showShare) {
            ActivityView(items: shareItems)
        }
    }

    private func togglePlay(_ memo: MemoRecording) {
        player.toggle(memo: memo)
    }
}

struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
