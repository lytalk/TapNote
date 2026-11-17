import SwiftUI

struct WatchLibraryView: View {
    @EnvironmentObject private var library: MemoLibraryStore
    @StateObject private var player = AudioPlayerService()

    var body: some View {
        List {
            if library.memos.isEmpty {
                Text("暂无录音")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(library.memos.prefix(30)) { memo in
                    NavigationLink {
                        WatchPlaybackView(memoID: memo.id)
                            .environmentObject(player)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(memo.title)
                                .font(.headline)
                            Text("\(Formatters.durationString(memo.duration)) · \(memo.sourceDevice)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("资料库")
        .onAppear { library.reloadFromDisk() }
        .onDisappear { player.stop() }
    }
}

struct WatchPlaybackView: View {
    let memoID: UUID
    @EnvironmentObject private var library: MemoLibraryStore
    @EnvironmentObject private var player: AudioPlayerService

    private var memo: MemoRecording? { library.memo(id: memoID) }

    var body: some View {
        Group {
            if let memo {
                VStack(spacing: 10) {
                    Text(memo.title)
                        .font(.headline)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)

                    Text("\(Formatters.durationString(player.playingID == memo.id ? player.currentTime : 0)) / \(Formatters.durationString(memo.duration))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)

                    Button {
                        player.toggle(memo: memo)
                    } label: {
                        Image(systemName: player.isPlaying && player.playingID == memo.id ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 52))
                            .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(player.isPlaying ? "暂停" : "播放")

                    if let err = player.lastError {
                        Text(err)
                            .font(.caption2)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(.horizontal, 4)
            } else {
                Text("录音不存在")
            }
        }
        .navigationTitle("播放")
        .onDisappear {
            if player.playingID == memoID {
                player.stop()
            }
        }
    }
}
