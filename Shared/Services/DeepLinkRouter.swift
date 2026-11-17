import Foundation

/// Coordinates complication / Action Button / URL quick-start into an active recording.
@MainActor
final class DeepLinkRouter: ObservableObject {
    static let shared = DeepLinkRouter()

    static let pendingAutoRecordKey = "tapnote.pendingAutoRecord"

    @Published var pendingAutoRecord = false

    func handle(url: URL) {
        guard url.scheme?.lowercased() == "tapnote" else { return }
        let host = (url.host ?? url.path).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if host == "record" || url.absoluteString.lowercased().contains("record") {
            markAutoRecord()
        }
    }

    func markAutoRecord() {
        pendingAutoRecord = true
        UserDefaults.standard.set(true, forKey: Self.pendingAutoRecordKey)
        AppLogger.record.info("Queued auto-record via deep link / intent")
    }

    /// Test / Shortcut helper: `-TapNoteAutoRecord` argv forces an immediate start.
    func ingestLaunchArgumentsIfNeeded() {
        if ProcessInfo.processInfo.arguments.contains("-TapNoteAutoRecord")
            || ProcessInfo.processInfo.environment["TAPNOTE_AUTO_RECORD"] == "1" {
            markAutoRecord()
        }
    }

    /// Consume a pending auto-record request (from URL, App Intent, or App Group defaults).
    @discardableResult
    func consumeAutoRecordIfNeeded() -> Bool {
        let fromDefaults = UserDefaults.standard.bool(forKey: Self.pendingAutoRecordKey)
        let should = pendingAutoRecord || fromDefaults
        pendingAutoRecord = false
        UserDefaults.standard.set(false, forKey: Self.pendingAutoRecordKey)
        return should
    }
}
