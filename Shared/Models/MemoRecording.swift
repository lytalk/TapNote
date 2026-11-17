import Foundation

enum RecordingStatus: String, Codable, Sendable {
    case recording
    case completed
    case failed
    case interrupted
}

enum TranscriptStatus: String, Codable, Sendable {
    case none
    case pending
    case processing
    case completed
    case failed
}

enum SummaryStatus: String, Codable, Sendable {
    case none
    case pending
    case processing
    case completed
    case failed
}

/// Shared memo metadata for iOS + watchOS. Audio lives beside JSON under the library root.
struct MemoRecording: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var title: String
    var createdAt: Date
    var duration: TimeInterval
    /// Relative path under the library root, e.g. `audio/<id>.m4a`.
    var audioRelativePath: String
    var recordingStatus: RecordingStatus
    var transcriptStatus: TranscriptStatus
    var transcriptText: String?
    /// Speaker-labeled segments when diarization ran; optional for older memos.
    var transcriptSegments: [TranscriptSegment]?
    var summaryStatus: SummaryStatus
    var summaryText: String?
    var updatedAt: Date
    /// Stable key used for iCloud file naming / conflict logs.
    var iCloudRecordID: String
    var sourceDevice: String

    init(
        id: UUID = UUID(),
        title: String? = nil,
        createdAt: Date = Date(),
        duration: TimeInterval = 0,
        audioRelativePath: String? = nil,
        recordingStatus: RecordingStatus = .recording,
        transcriptStatus: TranscriptStatus = .none,
        transcriptText: String? = nil,
        transcriptSegments: [TranscriptSegment]? = nil,
        summaryStatus: SummaryStatus = .none,
        summaryText: String? = nil,
        updatedAt: Date = Date(),
        iCloudRecordID: String? = nil,
        sourceDevice: String = MemoRecording.currentDeviceLabel()
    ) {
        self.id = id
        self.title = title ?? Self.defaultTitle(for: createdAt)
        self.createdAt = createdAt
        self.duration = duration
        self.audioRelativePath = audioRelativePath ?? "audio/\(id.uuidString).m4a"
        self.recordingStatus = recordingStatus
        self.transcriptStatus = transcriptStatus
        self.transcriptText = transcriptText
        self.transcriptSegments = transcriptSegments
        self.summaryStatus = summaryStatus
        self.summaryText = summaryText
        self.updatedAt = updatedAt
        self.iCloudRecordID = iCloudRecordID ?? id.uuidString
        self.sourceDevice = sourceDevice
    }

    var speakerCount: Int {
        Set(transcriptSegments?.map(\.speakerIndex) ?? []).count
    }

    mutating func touch() {
        updatedAt = Date()
    }

    static func defaultTitle(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 HH:mm"
        return "录音 \(formatter.string(from: date))"
    }

    static func currentDeviceLabel() -> String {
        #if os(watchOS)
        return "Apple Watch"
        #else
        return "iPhone"
        #endif
    }
}
