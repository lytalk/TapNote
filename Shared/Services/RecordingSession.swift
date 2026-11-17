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
    private var interruptionObserver: NSObjectProtocol?
    private var wasInterrupted = false
    private let store = AudioFileStore.shared

    /// Speech-friendly AAC: mono 16 kHz — smaller, stable for ASR / WC.
    static let recordingSettings: [String: Any] = [
        AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
        AVSampleRateKey: 16_000,
        AVNumberOfChannelsKey: 1,
        AVEncoderBitRateKey: 64_000,
        AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
    ]

    deinit {
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
        }
    }

    func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            if #available(iOS 17.0, watchOS 10.0, *) {
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            } else {
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
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

        AudioSessionCoordinator.deactivateGently()
        try AudioSessionCoordinator.activate(.record)
        observeInterruptions()

        let id = UUID()
        let tempURL = store.temporaryRecordingURL(id: id)

        let recorder = try AVAudioRecorder(url: tempURL, settings: Self.recordingSettings)
        recorder.isMeteringEnabled = true
        recorder.prepareToRecord()
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
        self.wasInterrupted = false

        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let started = self.startedAt else { return }
                self.elapsed = Date().timeIntervalSince(started)
                self.recorder?.updateMeters()
            }
        }

        AppLogger.record.info("Started recording \(id.uuidString, privacy: .public) 16k mono AAC")
        return MemoRecording(id: id, recordingStatus: .recording)
    }

    func stop() async throws -> (MemoRecording, URL) {
        guard isRecording, let recorder, let id = currentMemoID, let tempURL = activeTempURL else {
            throw RecordingError.notRecording
        }

        let duration = max(recorder.currentTime, 0)
        recorder.stop()
        timer?.invalidate()
        timer = nil
        isRecording = false
        elapsed = duration

        // Flush file to disk before Speech / WC reads it.
        try await Task.sleep(nanoseconds: 80_000_000)

        guard FileManager.default.fileExists(atPath: tempURL.path),
              (try? FileManager.default.attributesOfItem(atPath: tempURL.path)[.size] as? NSNumber)?.intValue ?? 0 > 0
        else {
            throw RecordingError.emptyFile
        }

        // Validate decodable by AVAudioFile.
        do {
            _ = try AVAudioFile(forReading: tempURL)
        } catch {
            AppLogger.record.error("Recorded file unreadable: \(error.localizedDescription)")
            throw RecordingError.corruptFile
        }

        var memo = MemoRecording(
            id: id,
            duration: duration,
            recordingStatus: wasInterrupted ? .interrupted : .completed
        )
        memo.touch()

        let dest = try store.moveRecordingIntoLibrary(from: tempURL, memo: memo)
        self.recorder = nil
        self.activeTempURL = nil
        self.currentMemoID = nil
        self.startedAt = nil

        AudioSessionCoordinator.deactivateGently()
        AppLogger.record.info("Stopped recording \(id.uuidString, privacy: .public) duration=\(duration) path=\(dest.lastPathComponent, privacy: .public)")
        return (memo, dest)
    }

    func markInterrupted() {
        guard isRecording else { return }
        wasInterrupted = true
        recorder?.pause()
        lastError = "录音被中断。可继续录音或结束并保存。"
        AppLogger.record.warning("Recording interrupted")
    }

    func resumeAfterInterruption() {
        guard isRecording, wasInterrupted, let recorder else { return }
        do {
            try AudioSessionCoordinator.activate(.record)
            if recorder.record() {
                wasInterrupted = false
                lastError = nil
                AppLogger.record.info("Recording resumed after interruption")
            }
        } catch {
            lastError = "无法从中断恢复：\(error.localizedDescription)"
        }
    }

    private func observeInterruptions() {
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
        }
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] note in
            Task { @MainActor in
                guard let self else { return }
                let typeValue = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                let type = typeValue.flatMap { AVAudioSession.InterruptionType(rawValue: $0) }
                switch type {
                case .began:
                    self.markInterrupted()
                case .ended:
                    let optionsValue = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                    let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                    if options.contains(.shouldResume) {
                        self.resumeAfterInterruption()
                    }
                default:
                    break
                }
            }
        }
    }
}

enum RecordingError: LocalizedError {
    case alreadyRecording
    case notRecording
    case permissionDenied
    case failedToStart
    case emptyFile
    case corruptFile

    var errorDescription: String? {
        switch self {
        case .alreadyRecording: return "已在录音中"
        case .notRecording: return "当前没有进行中的录音"
        case .permissionDenied: return "需要麦克风权限才能录音"
        case .failedToStart: return "无法开始录音"
        case .emptyFile: return "录音文件为空"
        case .corruptFile: return "录音文件损坏，无法读取"
        }
    }
}
