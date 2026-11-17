import Foundation
import OSLog

enum AppLogger {
    static let sync = Logger(subsystem: "com.lytalk.TapNote", category: "iCloud")
    static let record = Logger(subsystem: "com.lytalk.TapNote", category: "Recording")
    static let speech = Logger(subsystem: "com.lytalk.TapNote", category: "Speech")
    static let bridge = Logger(subsystem: "com.lytalk.TapNote", category: "WatchBridge")
    static let ai = Logger(subsystem: "com.lytalk.TapNote", category: "Summary")
}
