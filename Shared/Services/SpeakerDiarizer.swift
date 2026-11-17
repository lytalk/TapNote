import AVFoundation
import Accelerate
import Foundation

/// On-device multi-speaker labeling.
///
/// Apple SpeechAnalyzer / SpeechTranscriber provide **no** speaker diarization module (Xcode 27 / iOS 26–27 SDK).
/// This implementation:
/// 1. Takes time-indexed transcript utterances
/// 2. Extracts short spectral / pitch feature vectors from each utterance's PCM
/// 3. Agglomeratively clusters vectors by cosine distance
/// 4. Assigns "说话人 N" labels and merges adjacent same-speaker runs
///
/// Limit: heuristic timbre clustering — not neural speaker ID. Accuracy drops with similar voices,
/// heavy overlap, or very short turns. Documented in `docs/tapnote-recording-tech.md`.
enum SpeakerDiarizer {
    struct TimedUtterance: Sendable {
        var start: TimeInterval
        var end: TimeInterval
        var text: String
    }

    static func diarize(
        audioURL: URL,
        utterances: [TimedUtterance],
        maxSpeakers: Int = 4
    ) throws -> [TranscriptSegment] {
        guard !utterances.isEmpty else { return [] }

        let file = try AVAudioFile(forReading: audioURL)
        let format = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)
        else {
            return singleSpeakerFallback(utterances)
        }
        try file.read(into: buffer)

        var features: [[Float]] = []
        var validUtterances: [TimedUtterance] = []
        for u in utterances {
            let trimmed = u.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, u.end > u.start else { continue }
            if let vec = featureVector(buffer: buffer, start: u.start, end: u.end) {
                features.append(vec)
                validUtterances.append(TimedUtterance(start: u.start, end: u.end, text: trimmed))
            }
        }

        guard !validUtterances.isEmpty else { return singleSpeakerFallback(utterances) }

        if validUtterances.count == 1 || features.count < 2 {
            return [
                TranscriptSegment(
                    speakerIndex: 0,
                    startTime: validUtterances[0].start,
                    endTime: validUtterances[0].end,
                    text: validUtterances[0].text
                )
            ]
        }

        let labels = agglomerativeCluster(features: features, maxClusters: min(maxSpeakers, features.count))
        var segments: [TranscriptSegment] = []
        for (idx, u) in validUtterances.enumerated() {
            let speaker = labels[idx]
            if let last = segments.last, last.speakerIndex == speaker {
                var merged = last
                merged.endTime = u.end
                merged.text = mergeText(last.text, u.text)
                segments[segments.count - 1] = merged
            } else {
                segments.append(
                    TranscriptSegment(
                        speakerIndex: speaker,
                        startTime: u.start,
                        endTime: u.end,
                        text: u.text
                    )
                )
            }
        }

        // Relabel densely 0..<N by first appearance.
        var map: [Int: Int] = [:]
        var next = 0
        for i in segments.indices {
            let old = segments[i].speakerIndex
            if map[old] == nil {
                map[old] = next
                next += 1
            }
            let mapped = map[old]!
            segments[i].speakerIndex = mapped
            segments[i].speakerLabel = "说话人 \(mapped + 1)"
        }
        return segments
    }

    static func formattedTranscript(from segments: [TranscriptSegment]) -> String {
        segments.map { "[\($0.speakerLabel) · \($0.timeRangeLabel)]\n\($0.text)" }
            .joined(separator: "\n\n")
    }

    // MARK: - Features

    private static func featureVector(buffer: AVAudioPCMBuffer, start: TimeInterval, end: TimeInterval) -> [Float]? {
        guard let channel = buffer.floatChannelData?[0] else { return nil }
        let sr = buffer.format.sampleRate
        let startFrame = max(0, Int(start * sr))
        let endFrame = min(Int(buffer.frameLength), Int(end * sr))
        let count = endFrame - startFrame
        guard count > 64 else { return nil }

        var slice = [Float](repeating: 0, count: count)
        for i in 0..<count {
            slice[i] = channel[startFrame + i]
        }

        // RMS energy
        var rms: Float = 0
        vDSP_rmsqv(slice, 1, &rms, vDSP_Length(count))

        // Zero-crossing rate
        var zcr: Float = 0
        if count > 1 {
            var crossings = 0
            for i in 1..<count where (slice[i - 1] >= 0) != (slice[i] >= 0) {
                crossings += 1
            }
            zcr = Float(crossings) / Float(count)
        }

        // Spectral centroid via |FFT| magnitude (pad to power of 2)
        let n = 512
        var windowed = [Float](repeating: 0, count: n)
        let take = min(n, count)
        for i in 0..<take { windowed[i] = slice[i] }
        var window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        vDSP_vmul(windowed, 1, window, 1, &windowed, 1, vDSP_Length(n))

        let log2n = vDSP_Length(log2(Float(n)))
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            return [rms, zcr, 0, 0, 0, 0]
        }
        defer { vDSP_destroy_fftsetup(setup) }

        var realp = [Float](repeating: 0, count: n / 2)
        var imagp = [Float](repeating: 0, count: n / 2)
        realp.withUnsafeMutableBufferPointer { realBuf in
            imagp.withUnsafeMutableBufferPointer { imagBuf in
                var split = DSPSplitComplex(realp: realBuf.baseAddress!, imagp: imagBuf.baseAddress!)
                windowed.withUnsafeMutableBufferPointer { src in
                    src.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) { complex in
                        vDSP_ctoz(complex, 2, &split, 1, vDSP_Length(n / 2))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
            }
        }

        var mags = [Float](repeating: 0, count: n / 2)
        for i in 0..<(n / 2) {
            mags[i] = sqrtf(realp[i] * realp[i] + imagp[i] * imagp[i])
        }
        var magSum: Float = 0
        vDSP_sve(mags, 1, &magSum, vDSP_Length(n / 2))
        guard magSum > 1e-8 else { return [rms, zcr, 0, 0, 0, 0] }

        var weighted: Float = 0
        for i in 0..<(n / 2) {
            weighted += Float(i) * mags[i]
        }
        let centroid = weighted / magSum

        // 4 log-mel-ish bands
        let bands = 4
        let bandSize = (n / 2) / bands
        var bandEnergies = [Float](repeating: 0, count: bands)
        for b in 0..<bands {
            let lo = b * bandSize
            let hi = min((b + 1) * bandSize, n / 2)
            var s: Float = 0
            if hi > lo {
                let sub = Array(mags[lo..<hi])
                vDSP_sve(sub, 1, &s, vDSP_Length(sub.count))
            }
            bandEnergies[b] = logf(1 + s)
        }

        // Rough pitch via autocorrelation peak in 80–400 Hz
        let minLag = max(1, Int(sr / 400))
        let maxLag = min(count - 1, Int(sr / 80))
        var bestCorr: Float = 0
        var bestLag = minLag
        if maxLag > minLag {
            for lag in minLag...maxLag {
                var corr: Float = 0
                let len = count - lag
                slice.withUnsafeBufferPointer { ptr in
                    vDSP_dotpr(ptr.baseAddress!, 1, ptr.baseAddress! + lag, 1, &corr, vDSP_Length(len))
                }
                if corr > bestCorr {
                    bestCorr = corr
                    bestLag = lag
                }
            }
        }
        let pitch = Float(sr) / Float(max(bestLag, 1))

        var vec: [Float] = [rms, zcr, centroid / Float(n / 2), pitch / 400]
        vec.append(contentsOf: bandEnergies)
        // L2 normalize
        var norm: Float = 0
        vDSP_svesq(vec, 1, &norm, vDSP_Length(vec.count))
        norm = sqrtf(norm)
        if norm > 1e-8 {
            var scale = 1 / norm
            vDSP_vsmul(vec, 1, &scale, &vec, 1, vDSP_Length(vec.count))
        }
        return vec
    }

    // MARK: - Clustering

    private static func agglomerativeCluster(features: [[Float]], maxClusters: Int) -> [Int] {
        let n = features.count
        var labels = Array(0..<n)
        var active = Set(0..<n)
        var centroids = features

        func cosineDistance(_ a: [Float], _ b: [Float]) -> Float {
            var dot: Float = 0
            vDSP_dotpr(a, 1, b, 1, &dot, vDSP_Length(min(a.count, b.count)))
            return 1 - min(1, max(-1, dot))
        }

        while active.count > maxClusters {
            let ids = Array(active).sorted()
            var bestI = ids[0], bestJ = ids[1]
            var bestD = Float.greatestFiniteMagnitude
            for i in 0..<ids.count {
                for j in (i + 1)..<ids.count {
                    let d = cosineDistance(centroids[ids[i]], centroids[ids[j]])
                    if d < bestD {
                        bestD = d
                        bestI = ids[i]
                        bestJ = ids[j]
                    }
                }
            }
            // Keep merging until maxClusters unless distance is huge (very dissimilar).
            if bestD > 0.55 && active.count <= max(2, maxClusters) {
                break
            }
            // Merge j into i
            let membersI = labels.indices.filter { labels[$0] == bestI }
            let membersJ = labels.indices.filter { labels[$0] == bestJ }
            for m in membersJ { labels[m] = bestI }
            active.remove(bestJ)
            let all = membersI + membersJ
            var sum = [Float](repeating: 0, count: features[0].count)
            for m in all {
                vDSP_vadd(sum, 1, features[m], 1, &sum, 1, vDSP_Length(sum.count))
            }
            var scale = 1 / Float(all.count)
            vDSP_vsmul(sum, 1, &scale, &sum, 1, vDSP_Length(sum.count))
            centroids[bestI] = sum
        }

        // Compact labels
        let unique = Array(Set(labels)).sorted()
        let map = Dictionary(uniqueKeysWithValues: unique.enumerated().map { ($1, $0) })
        return labels.map { map[$0]! }
    }

    private static func singleSpeakerFallback(_ utterances: [TimedUtterance]) -> [TranscriptSegment] {
        let text = utterances.map(\.text).joined(separator: " ")
        let start = utterances.map(\.start).min() ?? 0
        let end = utterances.map(\.end).max() ?? start
        return [
            TranscriptSegment(speakerIndex: 0, startTime: start, endTime: end, text: text)
        ]
    }

    private static func mergeText(_ a: String, _ b: String) -> String {
        if a.hasSuffix(b) { return a }
        if b.hasPrefix(a) { return b }
        let joiner = (a.last?.isPunctuation == true || a.last?.isNewline == true) ? "" : " "
        return a + joiner + b
    }
}
