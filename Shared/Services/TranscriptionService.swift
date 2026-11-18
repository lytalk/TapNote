import AVFoundation
import Foundation
#if canImport(Speech)
import Speech
#endif

/// Native on-device transcription (+ optional speaker labels). No OpenAI / cloud LLM.
@MainActor
final class TranscriptionService: ObservableObject {
    static let shared = TranscriptionService()

    @Published private(set) var isTranscribing = false
    @Published private(set) var progressText: String?

    /// Serialize jobs — concurrent SpeechAnalyzer sessions were a top failure mode after first success.
    private var queue: [UUID] = []
    private var running = false
    private var activeLegacyTask: SFSpeechRecognitionTask?
    private var cancelRequested = false

    #if canImport(Speech) && os(iOS)

    func requestAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    func cancel() {
        cancelRequested = true
        queue.removeAll()
        activeLegacyTask?.cancel()
        activeLegacyTask = nil
        progressText = "已取消"
        isTranscribing = false
        AppLogger.speech.info("Transcription cancelled by user")
    }

    func transcribe(memoID: UUID) async {
        cancelRequested = false
        queue.append(memoID)
        await drainQueue()
    }

    private func drainQueue() async {
        guard !running else { return }
        running = true
        isTranscribing = true
        defer {
            running = false
            isTranscribing = false
            progressText = nil
            activeLegacyTask?.cancel()
            activeLegacyTask = nil
        }
        while !queue.isEmpty {
            if cancelRequested {
                queue.removeAll()
                break
            }
            let id = queue.removeFirst()
            await performTranscription(memoID: id)
        }
    }

    private func performTranscription(memoID: UUID) async {
        guard var memo = MemoLibraryStore.shared.memo(id: memoID) else { return }
        progressText = "准备转写…"
        memo.transcriptStatus = .processing
        MemoLibraryStore.shared.save(memo)

        defer {
            activeLegacyTask?.cancel()
            activeLegacyTask = nil
        }

        guard Bundle.main.object(forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription") != nil else {
            fail(memoID, "缺少语音识别用途说明（NSSpeechRecognitionUsageDescription）。")
            return
        }

        let auth = await requestAuthorization()
        guard auth == .authorized else {
            fail(memoID, "未授权语音识别，请在设置中开启。")
            return
        }
        if cancelRequested { return }

        let url = AudioFileStore.shared.audioURL(for: memo)
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        guard FileManager.default.fileExists(atPath: url.path) else {
            fail(memoID, "找不到音频文件，无法转写。")
            return
        }

        // File-based recognition is happier with a quiet session (no leftover playAndRecord).
        AudioSessionCoordinator.deactivateGently()
        try? await Task.sleep(nanoseconds: 150_000_000)
        if cancelRequested { return }

        let speechURL: URL
        do {
            progressText = "转换音频格式…"
            // Heavy AVAudioConverter work off the main actor so UI stays responsive.
            speechURL = try await Task.detached(priority: .userInitiated) {
                try AudioFormatPreparer.pcmCAFForSpeech(from: url)
            }.value
        } catch {
            AppLogger.speech.warning("PCM prepare failed, using original: \(error.localizedDescription)")
            speechURL = url
        }
        defer {
            if speechURL != url {
                try? FileManager.default.removeItem(at: speechURL)
            }
        }

        progressText = "转写中…"
        do {
            let result = try await recognizeWithBestEngine(url: speechURL)
            if cancelRequested { return }
            var updated = MemoLibraryStore.shared.memo(id: memoID) ?? memo
            updated.transcriptStatus = .completed
            updated.transcriptSegments = result.segments
            updated.transcriptText = result.displayText
            updated.touch()
            MemoLibraryStore.shared.save(updated)
            AppLogger.speech.info(
                "Transcribed \(memoID.uuidString, privacy: .public) engine=\(result.engine, privacy: .public) speakers=\(result.segments.map(\.speakerIndex).max().map { $0 + 1 } ?? 0)"
            )
        } catch is CancellationError {
            AppLogger.speech.info("Transcription cancelled for \(memoID.uuidString, privacy: .public)")
            if var current = MemoLibraryStore.shared.memo(id: memoID), current.transcriptStatus == .processing {
                current.transcriptStatus = .failed
                current.transcriptText = "已取消转写"
                current.touch()
                MemoLibraryStore.shared.save(current)
            }
        } catch {
            let message: String
            if let te = error as? TranscriptionError {
                message = te.errorDescription ?? te.localizedDescription
            } else {
                message = "转写失败：\(error.localizedDescription)"
            }
            fail(memoID, message)
            AppLogger.speech.error("Transcription failed: \(message, privacy: .public)")
        }

        AudioSessionCoordinator.deactivateGently()
    }

    private struct RecognizeResult: Sendable {
        var displayText: String
        var segments: [TranscriptSegment]
        var engine: String
    }

    private func recognizeWithBestEngine(url: URL) async throws -> RecognizeResult {
        if cancelRequested { throw CancellationError() }

        if #available(iOS 26.0, *) {
            #if !targetEnvironment(simulator)
            if SpeechTranscriber.isAvailable {
                do {
                    return try await withTimeout(seconds: 40) {
                        try await self.recognizeWithSpeechAnalyzer(url: url, useDictation: false)
                    }
                } catch let error as TranscriptionError where error == .emptyResult {
                    // Silence / no speech — skip DictationTranscriber (same empty outcome) and try SFSpeech once.
                    AppLogger.speech.warning("SpeechTranscriber empty; trying SFSpeech once")
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    AppLogger.speech.warning("SpeechTranscriber failed: \(error.localizedDescription)")
                    do {
                        return try await withTimeout(seconds: 40) {
                            try await self.recognizeWithSpeechAnalyzer(url: url, useDictation: true)
                        }
                    } catch let error as TranscriptionError where error == .emptyResult {
                        AppLogger.speech.warning("DictationTranscriber empty; trying SFSpeech once")
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        AppLogger.speech.warning("DictationTranscriber failed: \(error.localizedDescription)")
                    }
                }
            } else {
                do {
                    return try await withTimeout(seconds: 40) {
                        try await self.recognizeWithSpeechAnalyzer(url: url, useDictation: true)
                    }
                } catch let error as TranscriptionError where error == .emptyResult {
                    AppLogger.speech.warning("DictationTranscriber empty; trying SFSpeech once")
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    AppLogger.speech.warning("DictationTranscriber failed: \(error.localizedDescription)")
                }
            }
            #else
            AppLogger.speech.warning("Skipping SpeechAnalyzer on Simulator (models typically missing)")
            #endif
        }

        #if targetEnvironment(simulator)
        AppLogger.speech.error("Simulator Speech backend unavailable — use a physical iPhone with Speech models installed")
        throw TranscriptionError.simulatorSpeechUnavailable
        #else
        // Single SFSpeech attempt with hard timeout — never leave UI spinning after empty speech.
        do {
            return try await withTimeout(seconds: 25) {
                try await self.recognizeWithSFSpeech(url: url, onDevice: true, preferBuffer: true)
            }
        } catch let error as TranscriptionError where error == .emptyResult {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            AppLogger.speech.warning("SFSpeech on-device failed: \(error.localizedDescription); trying server")
        }
        return try await withTimeout(seconds: 25) {
            try await self.recognizeWithSFSpeech(url: url, onDevice: false, preferBuffer: true)
        }
        #endif
    }

    // MARK: - Timeout helper

    private func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @MainActor () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { @MainActor in
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw TranscriptionError.timeout
            }
            guard let value = try await group.next() else {
                throw TranscriptionError.timeout
            }
            group.cancelAll()
            return value
        }
    }

    // MARK: - SpeechAnalyzer (iOS 26+)

    @available(iOS 26.0, *)
    private func recognizeWithSpeechAnalyzer(url: URL, useDictation: Bool) async throws -> RecognizeResult {
        let preferred = Locale(identifier: "zh-CN")
        let module: any SpeechModule
        let engineName: String
        let locale: Locale

        if useDictation {
            if let zh = await DictationTranscriber.supportedLocale(equivalentTo: preferred) {
                locale = zh
            } else if let cur = await DictationTranscriber.supportedLocale(equivalentTo: Locale.current) {
                locale = cur
            } else {
                throw TranscriptionError.unsupportedLocale
            }
            module = DictationTranscriber(
                locale: locale,
                contentHints: [.farField],
                transcriptionOptions: [],
                reportingOptions: [],
                attributeOptions: [.audioTimeRange]
            )
            engineName = "DictationTranscriber"
        } else {
            if let zh = await SpeechTranscriber.supportedLocale(equivalentTo: preferred) {
                locale = zh
            } else if let cur = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) {
                locale = cur
            } else {
                throw TranscriptionError.unsupportedLocale
            }
            module = SpeechTranscriber(
                locale: locale,
                preset: .timeIndexedTranscriptionWithAlternatives
            )
            engineName = "SpeechTranscriber"
        }

        let status = await AssetInventory.status(forModules: [module])
        AppLogger.speech.info("Asset status for \(engineName, privacy: .public)=\(String(describing: status), privacy: .public)")
        if status == .unsupported {
            throw TranscriptionError.unsupportedLocale
        }
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            progressText = "下载语音模型…"
            try await request.downloadAndInstall()
        } else if status != .installed && status != .supported {
            throw TranscriptionError.unavailable
        }
        _ = try await AssetInventory.reserve(locale: locale)

        let analyzer = SpeechAnalyzer(modules: [module])
        if let fmt = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) {
            try await analyzer.prepareToAnalyze(in: fmt)
            AppLogger.speech.info("Analyzer format \(fmt.sampleRate)Hz ch=\(fmt.channelCount)")
        }

        let collectTask = Task { () -> [SpeakerDiarizer.TimedUtterance] in
            var utterances: [SpeakerDiarizer.TimedUtterance] = []
            if let transcriber = module as? SpeechTranscriber {
                for try await result in transcriber.results {
                    try Task.checkCancellation()
                    guard result.isFinal else { continue }
                    let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }
                    let start = CMTimeGetSeconds(result.range.start)
                    let end = start + CMTimeGetSeconds(result.range.duration)
                    utterances.append(.init(start: start, end: max(end, start + 0.05), text: text))
                }
            } else if let dictation = module as? DictationTranscriber {
                for try await result in dictation.results {
                    try Task.checkCancellation()
                    guard result.isFinal else { continue }
                    let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }
                    let start = CMTimeGetSeconds(result.range.start)
                    let end = start + CMTimeGetSeconds(result.range.duration)
                    utterances.append(.init(start: start, end: max(end, start + 0.05), text: text))
                }
            }
            return utterances
        }

        do {
            let asset = AVURLAsset(url: url)
            let lastTime: CMTime?
            if #available(iOS 27.0, *) {
                let provider = try await AssetInputSequenceProvider.provider(
                    from: asset,
                    compatibleWith: [module]
                )
                lastTime = try await analyzer.analyzeSequence(provider.analyzerInputs)
            } else {
                let audioFile = try AVAudioFile(forReading: url)
                lastTime = try await analyzer.analyzeSequence(from: audioFile)
            }
            if let lastTime {
                try await analyzer.finalizeAndFinish(through: lastTime)
            } else {
                try await analyzer.finalizeAndFinishThroughEndOfInput()
            }

            let utterances = try await collectTask.value
            guard !utterances.isEmpty else {
                throw TranscriptionError.emptyResult
            }

            let segments = try await Task.detached(priority: .userInitiated) {
                try SpeakerDiarizer.diarize(audioURL: url, utterances: utterances)
            }.value
            let display = SpeakerDiarizer.formattedTranscript(from: segments)
            return RecognizeResult(displayText: display, segments: segments, engine: engineName)
        } catch {
            collectTask.cancel()
            // Best-effort stop so the next engine / retry does not stall on a live analyzer.
            try? await analyzer.finalizeAndFinishThroughEndOfInput()
            throw error
        }
    }

    // MARK: - Legacy SFSpeechRecognizer (fallback)

    private func recognizeWithSFSpeech(url: URL, onDevice: Bool, preferBuffer: Bool) async throws -> RecognizeResult {
        let locales = [Locale(identifier: "zh-CN"), Locale(identifier: "en-US"), Locale.current]
        var recognizer: SFSpeechRecognizer?
        for loc in locales {
            if let r = SFSpeechRecognizer(locale: loc), r.isAvailable {
                recognizer = r
                break
            }
        }
        guard let recognizer else {
            throw TranscriptionError.unavailable
        }
        if onDevice, !recognizer.supportsOnDeviceRecognition {
            throw TranscriptionError.unavailable
        }

        let wavURL = try await Task.detached(priority: .userInitiated) {
            (try? AudioFormatPreparer.pcmWAVForSFSpeech(from: url)) ?? url
        }.value
        defer {
            if wavURL != url { try? FileManager.default.removeItem(at: wavURL) }
        }

        AppLogger.speech.info(
            "SFSpeech locale=\(recognizer.locale.identifier, privacy: .public) onDevice=\(onDevice) buffer=\(preferBuffer) file=\(wavURL.lastPathComponent, privacy: .public)"
        )

        let transcription: SFTranscription
        if preferBuffer {
            transcription = try await recognizeSFSpeechBuffer(
                recognizer: recognizer,
                wavURL: wavURL,
                onDevice: onDevice
            )
        } else {
            transcription = try await recognizeSFSpeechURL(
                recognizer: recognizer,
                fileURL: wavURL,
                onDevice: onDevice
            )
        }

        let trimmed = transcription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw TranscriptionError.emptyResult
        }

        let utterances: [SpeakerDiarizer.TimedUtterance] = transcription.segments.map { seg in
            SpeakerDiarizer.TimedUtterance(
                start: seg.timestamp,
                end: seg.timestamp + max(seg.duration, 0.05),
                text: seg.substring
            )
        }

        let grouped = groupByPause(utterances, pause: 0.55)
        let segments: [TranscriptSegment]
        if grouped.count >= 2 {
            segments = (try? await Task.detached {
                try SpeakerDiarizer.diarize(audioURL: url, utterances: grouped)
            }.value)
                ?? grouped.map {
                    TranscriptSegment(speakerIndex: 0, startTime: $0.start, endTime: $0.end, text: $0.text)
                }
        } else {
            segments = [
                TranscriptSegment(
                    speakerIndex: 0,
                    startTime: 0,
                    endTime: grouped.last?.end ?? 0,
                    text: trimmed
                )
            ]
        }

        let display = segments.count > 1
            ? SpeakerDiarizer.formattedTranscript(from: segments)
            : (segments.first?.text ?? trimmed)
        let engine = "SFSpeech-\(onDevice ? "onDevice" : "server")-\(preferBuffer ? "buffer" : "url")"
        return RecognizeResult(displayText: display, segments: segments, engine: engine)
    }

    private func recognizeSFSpeechURL(
        recognizer: SFSpeechRecognizer,
        fileURL: URL,
        onDevice: Bool
    ) async throws -> SFTranscription {
        let request = SFSpeechURLRecognitionRequest(url: fileURL)
        request.shouldReportPartialResults = false
        request.taskHint = .dictation
        request.requiresOnDeviceRecognition = onDevice
        return try await runSFSpeech(recognizer: recognizer, request: request, timeout: 18)
    }

    private func recognizeSFSpeechBuffer(
        recognizer: SFSpeechRecognizer,
        wavURL: URL,
        onDevice: Bool
    ) async throws -> SFTranscription {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = false
        request.taskHint = .dictation
        request.requiresOnDeviceRecognition = onDevice

        // Feed audio off the main actor — long files previously froze the UI here.
        let buffers: [AVAudioPCMBuffer] = try await Task.detached(priority: .userInitiated) {
            let file = try AVAudioFile(forReading: wavURL)
            let format = file.processingFormat
            let capacity: AVAudioFrameCount = 4096
            var out: [AVAudioPCMBuffer] = []
            while file.framePosition < file.length {
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { break }
                let remaining = AVAudioFrameCount(file.length - file.framePosition)
                buffer.frameLength = min(capacity, remaining)
                try file.read(into: buffer)
                out.append(buffer)
            }
            return out
        }.value

        guard !buffers.isEmpty else { throw TranscriptionError.unavailable }

        return try await withCheckedThrowingContinuation { continuation in
            var finished = false
            let finish: (Result<SFTranscription, Error>) -> Void = { result in
                guard !finished else { return }
                finished = true
                continuation.resume(with: result)
            }

            let timeoutWork = DispatchWorkItem {
                self.activeLegacyTask?.cancel()
                self.activeLegacyTask = nil
                finish(.failure(TranscriptionError.timeout))
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 22, execute: timeoutWork)

            let task = recognizer.recognitionTask(with: request) { result, error in
                if let error {
                    timeoutWork.cancel()
                    finish(.failure(error))
                    return
                }
                guard let result, result.isFinal else { return }
                timeoutWork.cancel()
                finish(.success(result.bestTranscription))
            }
            self.activeLegacyTask = task

            DispatchQueue.global(qos: .userInitiated).async {
                for buffer in buffers {
                    request.append(buffer)
                }
                request.endAudio()
            }
        }
    }

    private func runSFSpeech(
        recognizer: SFSpeechRecognizer,
        request: SFSpeechRecognitionRequest,
        timeout: TimeInterval
    ) async throws -> SFTranscription {
        try await withCheckedThrowingContinuation { continuation in
            var finished = false
            let finish: (Result<SFTranscription, Error>) -> Void = { result in
                guard !finished else { return }
                finished = true
                continuation.resume(with: result)
            }

            let timeoutWork = DispatchWorkItem {
                self.activeLegacyTask?.cancel()
                self.activeLegacyTask = nil
                finish(.failure(TranscriptionError.timeout))
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout, execute: timeoutWork)

            let task = recognizer.recognitionTask(with: request) { result, error in
                if let error {
                    timeoutWork.cancel()
                    finish(.failure(error))
                    return
                }
                guard let result, result.isFinal else { return }
                timeoutWork.cancel()
                finish(.success(result.bestTranscription))
            }
            self.activeLegacyTask = task
        }
    }

    private func groupByPause(
        _ words: [SpeakerDiarizer.TimedUtterance],
        pause: TimeInterval
    ) -> [SpeakerDiarizer.TimedUtterance] {
        guard let first = words.first else { return [] }
        var result: [SpeakerDiarizer.TimedUtterance] = []
        var current = first
        for w in words.dropFirst() {
            if w.start - current.end >= pause {
                result.append(current)
                current = w
            } else {
                current.end = w.end
                current.text = (current.text + w.text)
                    .replacingOccurrences(of: "  ", with: " ")
            }
        }
        result.append(current)
        return result
    }

    private func fail(_ memoID: UUID, _ message: String) {
        guard var memo = MemoLibraryStore.shared.memo(id: memoID) else { return }
        memo.transcriptStatus = .failed
        memo.transcriptText = message
        memo.touch()
        MemoLibraryStore.shared.save(memo)
        AppLogger.speech.error("\(message, privacy: .public)")
    }

    #else
    func transcribe(memoID: UUID) async {
        AppLogger.speech.warning("Speech unavailable on this platform; skip \(memoID.uuidString, privacy: .public)")
    }

    func cancel() {}
    #endif
}

enum TranscriptionError: LocalizedError, Equatable {
    case unsupportedLocale
    case unavailable
    case emptyResult
    case timeout
    case simulatorSpeechUnavailable

    var errorDescription: String? {
        switch self {
        case .unsupportedLocale: return "当前语言不受 Speech 支持"
        case .unavailable: return "当前设备无法使用语音识别"
        case .emptyResult: return "未识别到有效语音内容"
        case .timeout: return "转写超时，请重试（勿连续猛点）"
        case .simulatorSpeechUnavailable:
            return "模拟器 Speech 后端不可用（模型未装/zh-CN 资产损坏）。请在真机验证转写；多说话人聚类可在模拟器单独验证。"
        }
    }
}
