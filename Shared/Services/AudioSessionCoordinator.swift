import AVFoundation
import Foundation

/// Centralizes AVAudioSession transitions so recording / playback / Speech do not fight.
@MainActor
enum AudioSessionCoordinator {
    enum Purpose {
        case record
        case playback
        case speechAnalysis
    }

    static func activate(_ purpose: Purpose) throws {
        let session = AVAudioSession.sharedInstance()
        switch purpose {
        case .record:
            #if os(watchOS)
            try session.setCategory(.playAndRecord, mode: .default)
            #else
            try session.setCategory(
                .playAndRecord,
                mode: .spokenAudio,
                options: [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP]
            )
            #endif
            try session.setActive(true, options: [])
        case .playback:
            #if os(watchOS)
            try session.setCategory(.playback, mode: .default)
            #else
            try session.setCategory(.playback, mode: .spokenAudio, options: [.defaultToSpeaker])
            #endif
            try session.setActive(true, options: [])
        case .speechAnalysis:
            // SpeechAnalyzer / SFSpeech read files; avoid leftover playAndRecord / metering.
            #if os(iOS)
            try session.setCategory(.playback, mode: .measurement, options: [.mixWithOthers])
            try session.setActive(true, options: [])
            #endif
        }
    }

    static func deactivateGently() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
