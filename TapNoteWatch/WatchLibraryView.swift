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

    @State private var crownPosition: Double = 0
    @State private var isScrubbing = false
    @FocusState private var crownFocused: Bool

    private var memo: MemoRecording? { library.memo(id: memoID) }

    var body: some View {
        Group {
            if let memo {
                VStack(spacing: 8) {
                    Text(memo.title)
                        .font(.headline)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)

                    // Progress bar
                    ProgressView(
                        value: progressValue(for: memo),
                        total: max(memo.duration, 0.1)
                    )
                    .tint(.red)

                    Text("\(Formatters.durationString(displayTime(for: memo))) / \(Formatters.durationString(memo.duration))")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)

                    Text("转动表冠快进/快退")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    Button {
                        player.toggle(memo: memo)
                        syncCrown(from: player.currentTime)
                    } label: {
                        Image(systemName: player.isPlaying && player.playingID == memo.id ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 48))
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
                .padding(.horizontal, 2)
                .focusable(true)
                .focused($crownFocused)
                .digitalCrownRotation(
                    $crownPosition,
                    from: 0,
                    through: max(memo.duration, 0.1),
                    by: 0.25,
                    sensitivity: .medium,
                    isContinuous: false,
                    isHapticFeedbackEnabled: true
                )
                .onChange(of: crownPosition) { _, newValue in
                    isScrubbing = true
                    do {
                        try player.prepare(memo: memo, seekTo: newValue)
                    } catch {
                        player.lastError = error.localizedDescription
                    }
                    isScrubbing = false
                }
                .onChange(of: player.currentTime) { _, newValue in
                    guard !isScrubbing, player.playingID == memo.id else { return }
                    syncCrown(from: newValue)
                }
                .onAppear {
                    crownFocused = true
                    syncCrown(from: player.playingID == memo.id ? player.currentTime : 0)
                }
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

    private func displayTime(for memo: MemoRecording) -> TimeInterval {
        if isScrubbing { return crownPosition }
        return player.playingID == memo.id ? player.currentTime : crownPosition
    }

    private func progressValue(for memo: MemoRecording) -> Double {
        displayTime(for: memo)
    }

    private func syncCrown(from time: TimeInterval) {
        crownPosition = max(0, time)
    }
}
