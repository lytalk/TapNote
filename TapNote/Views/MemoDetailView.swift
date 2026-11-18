import SwiftUI

struct MemoDetailView: View {
    let memoID: UUID

    @EnvironmentObject private var library: MemoLibraryStore
    @EnvironmentObject private var player: AudioPlayerService
    /// Shared singleton — use ObservedObject (StateObject ownership is wrong here).
    @ObservedObject private var transcription = TranscriptionService.shared
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

            Section {
                if transcription.isTranscribing {
                    ProgressView(transcription.progressText ?? "转写中…")
                    Button("取消转写", role: .cancel) {
                        transcription.cancel()
                    }
                } else if memo.transcriptStatus == .completed {
                    if let segments = memo.transcriptSegments, !segments.isEmpty {
                        ForEach(segments) { segment in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(segment.speakerLabel)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(speakerColor(segment.speakerIndex))
                                    Spacer()
                                    Text(segment.timeRangeLabel)
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                                Text(segment.text)
                                    .textSelection(.enabled)
                            }
                            .padding(.vertical, 2)
                        }
                        if memo.speakerCount > 1 {
                            Text("检测到 \(memo.speakerCount) 位说话人（端侧频谱聚类，非神经说话人 ID）")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    } else if let text = memo.transcriptText {
                        Text(text)
                            .textSelection(.enabled)
                    }
                } else if memo.transcriptStatus == .failed {
                    Text(memo.transcriptText ?? "转写失败")
                        .foregroundStyle(.red)
                } else if memo.transcriptStatus == .processing {
                    // Stale processing without an active job — offer retry instead of spinning forever.
                    Text("转写中断，请重试")
                        .foregroundStyle(.secondary)
                } else {
                    Text("尚未转写")
                        .foregroundStyle(.secondary)
                }

                Button("转写 / 重试") {
                    Task { await transcription.transcribe(memoID: memo.id) }
                }
                .disabled(transcription.isTranscribing)
            } header: {
                Text("文稿（系统 Speech · 多说话人）")
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

    private func speakerColor(_ index: Int) -> Color {
        let palette: [Color] = [.indigo, .teal, .orange, .pink, .mint, .brown]
        return palette[index % palette.count]
    }
}

struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
