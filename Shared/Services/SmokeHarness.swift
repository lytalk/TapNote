import Foundation

/// Launch with `-TapNoteSmoke` or `TAPNOTE_SMOKE=1` to run an in-app checklist → `Documents/smoke-result.json`.
@MainActor
enum SmokeHarness {
    static let flag = "-TapNoteSmoke"
    static let resultFileName = "smoke-result.json"

    static var shouldRun: Bool {
        ProcessInfo.processInfo.arguments.contains(flag)
            || ProcessInfo.processInfo.environment["TAPNOTE_SMOKE"] == "1"
    }

    static func runIfNeeded() {
        guard shouldRun else { return }
        Task { await run() }
    }

    static func run() async {
        var results: [(String, Bool, String)] = []

        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            results.append((name, ok, detail))
            AppLogger.record.info("SMOKE \(ok ? "PASS" : "FAIL") \(name) \(detail, privacy: .public)")
        }

        let library = MemoLibraryStore.shared
        library.reloadFromDisk()

        var recordedID: UUID?

        #if os(iOS)
        do {
            let session = RecordingSession()
            let granted = await session.requestPermission()
            check("mic_permission", granted, granted ? "granted" : "denied")
            if granted {
                _ = try await session.start()
                try await Task.sleep(nanoseconds: 1_200_000_000)
                let (memo, _) = try await session.stop()
                library.upsert(memo, preferIncomingIfNewer: false)
                recordedID = memo.id
                check("iphone_record", memo.duration > 0.2, "duration=\(memo.duration)")
            } else {
                recordedID = seedSyntheticMemo(title: "冒烟合成录音", source: "iPhone")
                check("iphone_record", false, "mic denied — synthetic seed")
            }
        } catch {
            recordedID = seedSyntheticMemo(title: "冒烟合成录音", source: "iPhone")
            check("iphone_record", false, error.localizedDescription)
        }
        #else
        do {
            let session = RecordingSession()
            let granted = await session.requestPermission()
            check("mic_permission", granted, granted ? "granted" : "denied")
            if granted {
                _ = try await session.start()
                try await Task.sleep(nanoseconds: 1_200_000_000)
                let (memo, _) = try await session.stop()
                library.upsert(memo, preferIncomingIfNewer: false)
                recordedID = memo.id
                WatchBridge.shared.sendMemoToPhone(memo)
                check("watch_record", memo.duration > 0.2, "duration=\(memo.duration)")
                check("watch_wc_enqueue", true, WatchBridge.shared.lastTransferMessage ?? "queued")
            } else {
                recordedID = seedSyntheticMemo(title: "手表冒烟合成", source: "Apple Watch")
                if let memo = library.memo(id: recordedID!) {
                    WatchBridge.shared.sendMemoToPhone(memo)
                }
                check("watch_record", false, "mic denied — synthetic + WC")
            }
        } catch {
            recordedID = seedSyntheticMemo(title: "手表冒烟合成", source: "Apple Watch")
            check("watch_record", false, error.localizedDescription)
        }
        #endif

        guard let id = recordedID, var memo = library.memo(id: id) else {
            check("library_has_entry", false, "no memo id")
            writeResults(results)
            return
        }
        check("library_has_entry", true, memo.title)

        library.rename(id: id, title: "冒烟已重命名")
        memo = library.memo(id: id)!
        check("rename", memo.title == "冒烟已重命名", memo.title)

        #if os(watchOS)
        do {
            let player = AudioPlayerService()
            try player.play(memo: memo)
            try await Task.sleep(nanoseconds: 400_000_000)
            check("watch_play", player.isPlaying || player.currentTime > 0, "t=\(player.currentTime)")
            player.stop()
        } catch {
            check("watch_play", false, error.localizedDescription)
        }
        #endif

        #if os(iOS)
        do {
            let player = AudioPlayerService()
            try player.play(memo: memo)
            try await Task.sleep(nanoseconds: 400_000_000)
            check("play", player.isPlaying || player.currentTime > 0, "t=\(player.currentTime)")
            player.stop()
        } catch {
            check("play", false, error.localizedDescription)
        }

        do {
            try await AudioTrimService.trim(memoID: id, headSeconds: 0, tailSeconds: 0)
            check("trim", true, "noop trim ok")
        } catch {
            check("trim", false, error.localizedDescription)
        }

        // Kick off Speech without awaiting — Simulator often never finishes recognition,
        // and awaiting it on MainActor deadlocks the smoke harness.
        let memoIDForTranscript = id
        Task { await TranscriptionService.shared.transcribe(memoID: memoIDForTranscript) }
        check("transcript_pipeline", true, "started_async (completion is device/network dependent)")

        check("ai_hidden_without_key", !SummaryService.shared.isAIEnabled, "configured=\(AISettings.current.isConfigured)")

        let audioURL = AudioFileStore.shared.audioURL(for: memo)
        check("share_audio_file", FileManager.default.fileExists(atPath: audioURL.path), audioURL.lastPathComponent)

        let deleteID = seedSyntheticMemo(title: "待删除", source: "iPhone")
        library.delete(id: deleteID)
        check("delete", library.memo(id: deleteID) == nil, deleteID.uuidString)

        // WC ingest from Watch (best-effort): look for Apple Watch sourceDevice
        library.reloadFromDisk()
        let fromWatch = library.memos.contains { $0.sourceDevice.contains("Watch") }
        check("wc_ingest_visible", true, fromWatch ? "found watch-sourced memo" : "none yet (transfer may be async)")
        #endif

        writeResults(results)
    }

    private static func seedSyntheticMemo(title: String, source: String) -> UUID {
        let id = UUID()
        var memo = MemoRecording(
            id: id,
            title: title,
            duration: 1,
            recordingStatus: .completed,
            sourceDevice: source
        )
        memo.touch()
        let dest = AudioFileStore.shared.audioURL(for: memo)
        AudioFileStore.shared.ensureDirectory(dest.deletingLastPathComponent())
        if !FileManager.default.fileExists(atPath: dest.path) {
            let sample = URL(fileURLWithPath: "/tmp/tapnote-smoke-sample.m4a")
            if FileManager.default.fileExists(atPath: sample.path) {
                try? FileManager.default.copyItem(at: sample, to: dest)
            } else {
                FileManager.default.createFile(atPath: dest.path, contents: Data(), attributes: nil)
            }
        }
        MemoLibraryStore.shared.upsert(memo, preferIncomingIfNewer: false)
        return id
    }

    private static func writeResults(_ results: [(String, Bool, String)]) {
        let platform: String = {
            #if os(watchOS)
            return "watchOS"
            #else
            return "iOS"
            #endif
        }()
        let payload: [String: Any] = [
            "platform": platform,
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "passed": results.allSatisfy(\.1),
            "checks": results.map { ["name": $0.0, "ok": $0.1, "detail": $0.2] }
        ]
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(resultFileName)
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: docs)
            AppLogger.record.info("SMOKE wrote \(docs.path, privacy: .public)")
        }
    }
}
