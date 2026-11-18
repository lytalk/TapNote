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
            // watchOS: keep it simple — exotic Bluetooth options break record() on device.
            try session.setCategory(.playAndRecord, mode: .default, options: [])
            #else
            // Avoid .allowBluetoothA2DP with playAndRecord (A2DP is output-only; can make record() return false).
            // Prefer HFP when a headset mic is connected.
            if #available(iOS 18.0, *) {
                try session.setCategory(
                    .playAndRecord,
                    mode: .default,
                    options: [.defaultToSpeaker, .allowBluetoothHFP]
                )
            } else {
                try session.setCategory(
                    .playAndRecord,
                    mode: .default,
                    options: [.defaultToSpeaker, .allowBluetooth]
                )
            }
            #endif
            try session.setActive(true, options: [])
        case .playback:
            #if os(watchOS)
            try session.setCategory(.playback, mode: .default)
            #else
            try session.setCategory(.playback, mode: .default, options: [.defaultToSpeaker])
            #endif
            try session.setActive(true, options: [])
        case .speechAnalysis:
            #if os(iOS)
            try session.setCategory(.playback, mode: .measurement, options: [.mixWithOthers])
            try session.setActive(true, options: [])
            #endif
        }
    }

    /// Prefer switching category without tearing the session down first (device race).
    static func deactivateGently() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
