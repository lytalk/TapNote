import Foundation

/// One contiguous utterance attributed to a speaker label.
struct TranscriptSegment: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    /// 0-based speaker index within this memo.
    var speakerIndex: Int
    /// Display label, e.g. "说话人 1".
    var speakerLabel: String
    var startTime: TimeInterval
    var endTime: TimeInterval
    var text: String

    init(
        id: UUID = UUID(),
        speakerIndex: Int,
        speakerLabel: String? = nil,
        startTime: TimeInterval,
        endTime: TimeInterval,
        text: String
    ) {
        self.id = id
        self.speakerIndex = speakerIndex
        self.speakerLabel = speakerLabel ?? "说话人 \(speakerIndex + 1)"
        self.startTime = startTime
        self.endTime = endTime
        self.text = text
    }

    var timeRangeLabel: String {
        "\(Formatters.durationString(startTime))–\(Formatters.durationString(endTime))"
    }
}
