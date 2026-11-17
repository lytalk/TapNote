import AVFoundation
import Foundation

@MainActor
final class AudioPlayerService: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var playingID: UUID?
    @Published var lastError: String?

    private var player: AVAudioPlayer?
    private var tick: Timer?

    func play(memo: MemoRecording) throws {
        stop()
        lastError = nil
        let url = AudioFileStore.shared.audioURL(for: memo)
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)

        guard FileManager.default.fileExists(atPath: url.path) else {
            lastError = "找不到音频文件"
            throw PlaybackError.fileMissing
        }

        try AudioSessionCoordinator.activate(.playback)

        let player = try AVAudioPlayer(contentsOf: url)
        player.delegate = self
        player.prepareToPlay()
        guard player.play() else {
            lastError = "无法开始播放"
            throw PlaybackError.failedToPlay
        }
        self.player = player
        self.playingID = memo.id
        self.duration = player.duration
        self.isPlaying = true
        startTick()
        AppLogger.record.info("Playing \(memo.id.uuidString, privacy: .public) path=\(url.lastPathComponent, privacy: .public)")
    }

    func toggle(memo: MemoRecording) {
        do {
            if playingID == memo.id, isPlaying {
                pause()
            } else if playingID == memo.id {
                resume()
            } else {
                try play(memo: memo)
            }
        } catch {
            lastError = error.localizedDescription
            AppLogger.record.error("Play failed: \(error.localizedDescription)")
        }
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
        let clamped = max(0, min(time, player?.duration ?? time))
        player?.currentTime = clamped
        currentTime = clamped
    }

    /// Load audio for scrubbing without forcing playback if already prepared.
    func prepare(memo: MemoRecording, seekTo time: TimeInterval? = nil) throws {
        lastError = nil
        if playingID != memo.id || player == nil {
            let url = AudioFileStore.shared.audioURL(for: memo)
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
            guard FileManager.default.fileExists(atPath: url.path) else {
                lastError = "找不到音频文件"
                throw PlaybackError.fileMissing
            }
            try AudioSessionCoordinator.activate(.playback)
            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = self
            player.prepareToPlay()
            self.player = player
            self.playingID = memo.id
            self.duration = player.duration
            self.isPlaying = false
        }
        if let time {
            seek(to: time)
        }
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

enum PlaybackError: LocalizedError {
    case fileMissing
    case failedToPlay

    var errorDescription: String? {
        switch self {
        case .fileMissing: return "找不到音频文件"
        case .failedToPlay: return "无法开始播放"
        }
    }
}
