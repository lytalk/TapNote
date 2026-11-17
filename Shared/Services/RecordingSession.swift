import AVFoundation
import Foundation

@MainActor
final class RecordingSession: NSObject, ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var currentMemoID: UUID?
    @Published var lastError: String?

    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var startedAt: Date?
    private var activeTempURL: URL?
    private let store = AudioFileStore.shared

    func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    func start() async throws -> MemoRecording {
        guard !isRecording else {
            throw RecordingError.alreadyRecording
        }
        let granted = await requestPermission()
        guard granted else {
            throw RecordingError.permissionDenied
        }

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .spokenAudio,
            options: [.defaultToSpeaker, .allowBluetooth]
        )
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        let id = UUID()
        let tempURL = store.temporaryRecordingURL(id: id)
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        let recorder = try AVAudioRecorder(url: tempURL, settings: settings)
        recorder.isMeteringEnabled = true
        guard recorder.record() else {
            throw RecordingError.failedToStart
        }

        self.recorder = recorder
        self.activeTempURL = tempURL
        self.currentMemoID = id
        self.startedAt = Date()
        self.elapsed = 0
        self.isRecording = true
        self.lastError = nil

        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let started = self.startedAt else { return }
                self.elapsed = Date().timeIntervalSince(started)
            }
        }

        AppLogger.record.info("Started recording \(id.uuidString, privacy: .public)")
        return MemoRecording(id: id, recordingStatus: .recording)
    }

    func stop() async throws -> (MemoRecording, URL) {
        guard isRecording, let recorder, let id = currentMemoID, let tempURL = activeTempURL else {
            throw RecordingError.notRecording
        }

        let duration = recorder.currentTime
        recorder.stop()
        timer?.invalidate()
        timer = nil
        isRecording = false
        elapsed = duration

        var memo = MemoRecording(
            id: id,
            duration: duration,
            recordingStatus: .completed
        )
        memo.touch()

        let dest = try store.moveRecordingIntoLibrary(from: tempURL, memo: memo)
        self.recorder = nil
        self.activeTempURL = nil
        self.currentMemoID = nil
        self.startedAt = nil

        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        AppLogger.record.info("Stopped recording \(id.uuidString, privacy: .public) duration=\(duration)")
        return (memo, dest)
    }

    func markInterrupted() {
        guard isRecording else { return }
        recorder?.pause()
        lastError = "录音被中断，请重新打开应用继续或结束录音。"
        AppLogger.record.warning("Recording interrupted")
    }
}

enum RecordingError: LocalizedError {
    case alreadyRecording
    case notRecording
    case permissionDenied
    case failedToStart

    var errorDescription: String? {
        switch self {
        case .alreadyRecording: return "已在录音中"
        case .notRecording: return "当前没有进行中的录音"
        case .permissionDenied: return "需要麦克风权限才能录音"
        case .failedToStart: return "无法开始录音"
        }
    }
}
