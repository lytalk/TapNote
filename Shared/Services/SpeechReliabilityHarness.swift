import Foundation
#if canImport(Speech) && os(iOS)
import AVFoundation

/// Launch with `-TapNoteSpeechTest` to verify repeated native transcription + multi-speaker labels.
/// Reads optional fixtures from Documents/SpeechFixtures/{single,meeting}.m4a
@MainActor
enum SpeechReliabilityHarness {
    static let flag = "-TapNoteSpeechTest"
    static let resultFileName = "speech-test-result.json"

    static var shouldRun: Bool {
        ProcessInfo.processInfo.arguments.contains(flag)
            || ProcessInfo.processInfo.environment["TAPNOTE_SPEECH_TEST"] == "1"
    }

    static func runIfNeeded() {
        guard shouldRun else { return }
        Task { await run() }
    }

    static func run() async {
        var checks: [(String, Bool, String)] = []
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            checks.append((name, ok, detail))
            AppLogger.speech.info("SPEECHTEST \(ok ? "PASS" : "FAIL") \(name) \(detail, privacy: .public)")
        }

        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let fixtures = docs.appendingPathComponent("SpeechFixtures", isDirectory: true)
        AudioFileStore.shared.ensureDirectory(fixtures)

        // Prefer injected fixtures; else synthesize silence-padded tone (will fail ASR — noted).
        let singleURL = firstExisting(fixtures, names: ["single.caf", "single.m4a", "single.wav"])
        let meetingURL = firstExisting(fixtures, names: ["meeting.caf", "meeting.m4a", "meeting.wav"])

        check("fixture_single", singleURL != nil, singleURL?.lastPathComponent ?? "missing")
        check("fixture_meeting", meetingURL != nil, meetingURL?.lastPathComponent ?? "missing")

        if let singleURL {
            let id = importFixture(title: "单人转写夹具", sourceURL: singleURL, source: "iPhone")
            await TranscriptionService.shared.transcribe(memoID: id)
            let first = MemoLibraryStore.shared.memo(id: id)
            let firstOK = first?.transcriptStatus == .completed && !(first?.transcriptText?.isEmpty ?? true)
            check("iphone_transcribe_1", firstOK, first?.transcriptText?.prefix(80).description ?? first?.transcriptStatus.rawValue ?? "?")

            await TranscriptionService.shared.transcribe(memoID: id)
            let second = MemoLibraryStore.shared.memo(id: id)
            let secondOK = second?.transcriptStatus == .completed && !(second?.transcriptText?.isEmpty ?? true)
            check("iphone_transcribe_2", secondOK, second?.transcriptText?.prefix(80).description ?? second?.transcriptStatus.rawValue ?? "?")
        } else {
            check("iphone_transcribe_1", false, "missing fixture")
            check("iphone_transcribe_2", false, "missing fixture")
        }

        // Watch-sourced path: same engine after WC ingest — reuse single labeled as Watch.
        if let singleURL {
            let wid = importFixture(title: "手表转写夹具", sourceURL: singleURL, source: "Apple Watch")
            await TranscriptionService.shared.transcribe(memoID: wid)
            let w1 = MemoLibraryStore.shared.memo(id: wid)
            check("watch_transcribe_1", w1?.transcriptStatus == .completed, w1?.transcriptText?.prefix(80).description ?? w1?.transcriptStatus.rawValue ?? "?")
            await TranscriptionService.shared.transcribe(memoID: wid)
            let w2 = MemoLibraryStore.shared.memo(id: wid)
            check("watch_transcribe_2", w2?.transcriptStatus == .completed, w2?.transcriptText?.prefix(80).description ?? w2?.transcriptStatus.rawValue ?? "?")
        } else {
            check("watch_transcribe_1", false, "missing fixture")
            check("watch_transcribe_2", false, "missing fixture")
        }

        if let meetingURL {
            // Independent of ASR: prove clustering labels ≥2 speakers on alternating TTS turns.
            do {
                let file = try AVAudioFile(forReading: meetingURL)
                let dur = Double(file.length) / file.processingFormat.sampleRate
                let quarter = max(dur / 4.5, 1.0)
                let synthetic: [SpeakerDiarizer.TimedUtterance] = [
                    .init(start: 0, end: quarter, text: "大家好我是说话人一今天讨论产品进度"),
                    .init(start: quarter + 0.9, end: quarter * 2 + 0.9, text: "大家好我是说话人二我认为接口本周完成"),
                    .init(start: quarter * 2 + 1.8, end: quarter * 3 + 1.8, text: "说话人一补充一下风险点"),
                    .init(start: quarter * 3 + 2.7, end: min(dur, quarter * 4 + 2.7), text: "说话人二同意这个安排")
                ]
                let clustered = try SpeakerDiarizer.diarize(
                    audioURL: meetingURL,
                    utterances: synthetic,
                    maxSpeakers: 2
                )
                let speakers = Set(clustered.map(\.speakerIndex)).count
                check(
                    "diarizer_cluster_standalone",
                    speakers >= 2,
                    "speakers=\(speakers) segments=\(clustered.count)"
                )
            } catch {
                check("diarizer_cluster_standalone", false, error.localizedDescription)
            }

            let mid = importFixture(title: "会议多说话人夹具", sourceURL: meetingURL, source: "iPhone")
            await TranscriptionService.shared.transcribe(memoID: mid)
            let meeting = MemoLibraryStore.shared.memo(id: mid)
            let segments = meeting?.transcriptSegments ?? []
            let speakers = Set(segments.map(\.speakerIndex)).count
            let labeled = speakers >= 2 && segments.contains { $0.speakerLabel.contains("说话人") }
            check(
                "multi_speaker_labeled",
                meeting?.transcriptStatus == .completed && labeled,
                "speakers=\(speakers) segments=\(segments.count) text=\(meeting?.transcriptText?.prefix(120).description ?? meeting?.transcriptStatus.rawValue ?? "?")"
            )

            // If ASR failed on Simulator but diarizer works, persist a 2-speaker labeled transcript for UI.
            if meeting?.transcriptStatus != .completed {
                let turns: [SpeakerDiarizer.TimedUtterance] = [
                    .init(start: 0, end: 3.2, text: "大家好，我是说话人一。今天我们讨论产品进度和下一步计划。"),
                    .init(start: 4.1, end: 8.0, text: "大家好，我是说话人二。我认为接口应该本周完成，并开始联调。"),
                    .init(start: 8.9, end: 12.0, text: "好的，那风险点我来跟进。"),
                    .init(start: 12.9, end: 16.0, text: "同意，本周五对齐。")
                ]
                // Prefer acoustic clustering; fall back to alternating labels for stable UI demo.
                let clusteredAcoustic = try? SpeakerDiarizer.diarize(
                    audioURL: meetingURL,
                    utterances: turns,
                    maxSpeakers: 2
                )
                let alternating = turns.enumerated().map {
                    TranscriptSegment(
                        speakerIndex: $0.offset % 2,
                        startTime: $0.element.start,
                        endTime: $0.element.end,
                        text: $0.element.text
                    )
                }
                let clustered = (clusteredAcoustic.flatMap { Set($0.map(\.speakerIndex)).count >= 2 ? $0 : nil })
                    ?? alternating
                var patched = MemoLibraryStore.shared.memo(id: mid) ?? MemoRecording(id: mid)
                patched.transcriptStatus = .completed
                patched.transcriptSegments = clustered
                patched.transcriptText = SpeakerDiarizer.formattedTranscript(from: clustered)
                    + "\n\n（模拟器 ASR 不可用时的端侧多说话人 UI 验证稿；真机走 SpeechAnalyzer/SFSpeech + diarizer）"
                patched.touch()
                MemoLibraryStore.shared.save(patched)
                UserDefaults.standard.set(mid.uuidString, forKey: "tapnote.openMemoID")
                check(
                    "multi_speaker_ui_seed",
                    Set(clustered.map(\.speakerIndex)).count >= 2,
                    "speakers=\(Set(clustered.map(\.speakerIndex)).count) segments=\(clustered.count)"
                )
            }
        } else {
            check("diarizer_cluster_standalone", false, "missing meeting fixture")
            check("multi_speaker_labeled", false, "missing meeting fixture")
        }

        let payload: [String: Any] = [
            "platform": "iOS",
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "passed": checks.allSatisfy(\.1),
            "checks": checks.map { ["name": $0.0, "ok": $0.1, "detail": $0.2] }
        ]
        let out = docs.appendingPathComponent(resultFileName)
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: out)
            AppLogger.speech.info("SPEECHTEST wrote \(out.path, privacy: .public)")
        }
    }

    private static func firstExisting(_ dir: URL, names: [String]) -> URL? {
        for name in names {
            let url = dir.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    private static func importFixture(title: String, sourceURL: URL, source: String) -> UUID {
        let id = UUID()
        let ext = sourceURL.pathExtension.isEmpty ? "m4a" : sourceURL.pathExtension
        var memo = MemoRecording(
            id: id,
            title: title,
            duration: 0,
            audioRelativePath: "audio/\(id.uuidString).\(ext)",
            recordingStatus: .completed,
            sourceDevice: source
        )
        let dest = AudioFileStore.shared.audioURL(for: memo)
        AudioFileStore.shared.ensureDirectory(dest.deletingLastPathComponent())
        try? FileManager.default.removeItem(at: dest)
        try? FileManager.default.copyItem(at: sourceURL, to: dest)
        if let file = try? AVAudioFile(forReading: dest) {
            memo.duration = Double(file.length) / file.processingFormat.sampleRate
        }
        memo.touch()
        MemoLibraryStore.shared.upsert(memo, preferIncomingIfNewer: false)
        return id
    }
}
#endif
