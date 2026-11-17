import AVFoundation
import Foundation

@MainActor
final class AudioPlayerService: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var playingID: UUID?

    private var player: AVAudioPlayer?
    private var tick: Timer?

    func play(memo: MemoRecording) throws {
        stop()
        let url = AudioFileStore.shared.audioURL(for: memo)
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .spokenAudio)
        try session.setActive(true)

        let player = try AVAudioPlayer(contentsOf: url)
        player.delegate = self
        player.prepareToPlay()
        player.play()
        self.player = player
        self.playingID = memo.id
        self.duration = player.duration
        self.isPlaying = true
        startTick()
    }

    func pause() {
        player?.pause()
        isPlaying = false
        tick?.invalidate()
    }

    func resume() {
        player?.play()
        isPlaying = true
        startTick()
    }

    func stop() {
        player?.stop()
        player = nil
        isPlaying = false
        playingID = nil
        currentTime = 0
        tick?.invalidate()
    }

    func seek(to time: TimeInterval) {
        player?.currentTime = time
        currentTime = time
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.isPlaying = false
            self.currentTime = self.duration
            self.tick?.invalidate()
        }
    }

    private func startTick() {
        tick?.invalidate()
        tick = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.currentTime = self?.player?.currentTime ?? 0
            }
        }
    }
}
