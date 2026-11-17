import AVFoundation
import Foundation

/// Converts library AAC/m4a into Speech-friendly PCM (16 kHz mono).
enum AudioFormatPreparer {
    enum OutputKind {
        /// Float32 CAF — good for SpeechAnalyzer buffer paths.
        case floatCAF
        /// Int16 WAV — historically the most reliable for SFSpeechURLRecognitionRequest.
        case int16WAV
    }

    static func pcmCAFForSpeech(from sourceURL: URL) throws -> URL {
        try convert(from: sourceURL, kind: .floatCAF)
    }

    static func pcmWAVForSFSpeech(from sourceURL: URL) throws -> URL {
        try convert(from: sourceURL, kind: .int16WAV)
    }

    static func convert(from sourceURL: URL, kind: OutputKind) throws -> URL {
        let source = try AVAudioFile(forReading: sourceURL)
        let sourceFormat = source.processingFormat

        let targetFormat: AVAudioFormat
        let outURL: URL
        switch kind {
        case .floatCAF:
            guard let fmt = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 16_000,
                channels: 1,
                interleaved: false
            ) else { throw PreparError.badFormat }
            targetFormat = fmt
            outURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("tapnote-speech-\(UUID().uuidString).caf")
        case .int16WAV:
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatLinearPCM),
                AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ]
            guard let fmt = AVAudioFormat(settings: settings) else { throw PreparError.badFormat }
            targetFormat = fmt
            outURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("tapnote-speech-\(UUID().uuidString).wav")
        }

        let destination = try AVAudioFile(forWriting: outURL, settings: targetFormat.settings)

        let frameCapacity: AVAudioFrameCount = 4096
        guard let srcBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frameCapacity) else {
            throw PreparError.badFormat
        }

        if sourceFormat.sampleRate == targetFormat.sampleRate,
           sourceFormat.channelCount == targetFormat.channelCount,
           sourceFormat.commonFormat == targetFormat.commonFormat {
            while source.framePosition < source.length {
                let remaining = AVAudioFrameCount(source.length - source.framePosition)
                srcBuffer.frameLength = min(frameCapacity, remaining)
                try source.read(into: srcBuffer)
                try destination.write(from: srcBuffer)
            }
            return outURL
        }

        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            throw PreparError.converter
        }
        guard let dstBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCapacity) else {
            throw PreparError.badFormat
        }

        var done = false
        while !done {
            dstBuffer.frameLength = 0
            var error: NSError?
            let status = converter.convert(to: dstBuffer, error: &error) { _, outStatus in
                do {
                    let remaining = AVAudioFrameCount(source.length - source.framePosition)
                    if remaining == 0 {
                        outStatus.pointee = .endOfStream
                        return nil
                    }
                    srcBuffer.frameLength = min(frameCapacity, remaining)
                    try source.read(into: srcBuffer)
                    outStatus.pointee = .haveData
                    return srcBuffer
                } catch {
                    outStatus.pointee = .endOfStream
                    return nil
                }
            }
            if let error { throw error }
            if status == .error { throw PreparError.converter }
            if status == .endOfStream {
                done = true
                if dstBuffer.frameLength > 0 {
                    try destination.write(from: dstBuffer)
                }
                break
            }
            if dstBuffer.frameLength > 0 {
                try destination.write(from: dstBuffer)
            }
        }

        AppLogger.speech.info(
            "Prepared PCM CAF \(outURL.lastPathComponent, privacy: .public) from \(sourceURL.lastPathComponent, privacy: .public)"
        )
        return outURL
    }

    enum PreparError: LocalizedError {
        case badFormat
        case converter
        var errorDescription: String? {
            switch self {
            case .badFormat: return "无法创建语音分析音频格式"
            case .converter: return "音频格式转换失败"
            }
        }
    }
}
