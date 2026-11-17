import AVFoundation
import Foundation

enum AudioTrimService {
    /// Trims head/tail seconds and replaces the memo audio in-place.
    @MainActor
    static func trim(memoID: UUID, headSeconds: TimeInterval, tailSeconds: TimeInterval) async throws {
        guard var memo = MemoLibraryStore.shared.memo(id: memoID) else {
            throw TrimError.memoMissing
        }
        let sourceURL = AudioFileStore.shared.audioURL(for: memo)
        let asset = AVURLAsset(url: sourceURL)
        let duration = try await asset.load(.duration).seconds
        let start = max(0, headSeconds)
        let end = max(start + 0.1, duration - max(0, tailSeconds))
        guard end > start else { throw TrimError.invalidRange }

        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw TrimError.exportFailed
        }
        let assetTrack = try await asset.loadTracks(withMediaType: .audio).first
        guard let assetTrack else { throw TrimError.exportFailed }

        let timeRange = CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 600),
            end: CMTime(seconds: end, preferredTimescale: 600)
        )
        try track.insertTimeRange(timeRange, of: assetTrack, at: .zero)

        let exportURL = AudioFileStore.shared.temporaryRecordingURL(id: UUID())
        if FileManager.default.fileExists(atPath: exportURL.path) {
            try FileManager.default.removeItem(at: exportURL)
        }

        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
            throw TrimError.exportFailed
        }
        export.outputURL = exportURL
        export.outputFileType = .m4a
        await export.export()
        guard export.status == .completed else {
            throw TrimError.exportFailed
        }

        let dest = AudioFileStore.shared.audioURL(for: memo)
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.moveItem(at: exportURL, to: dest)

        memo.duration = end - start
        memo.touch()
        MemoLibraryStore.shared.upsert(memo, preferIncomingIfNewer: false)
    }
}

enum TrimError: LocalizedError {
    case memoMissing
    case invalidRange
    case exportFailed

    var errorDescription: String? {
        switch self {
        case .memoMissing: return "找不到录音"
        case .invalidRange: return "裁剪范围无效"
        case .exportFailed: return "导出裁剪失败"
        }
    }
}
