import Foundation

/// Coordinates complication / Action Button / URL quick-start into an active recording.
@MainActor
final class DeepLinkRouter: ObservableObject {
    static let shared = DeepLinkRouter()

    static let pendingAutoRecordKey = "tapnote.pendingAutoRecord"

    @Published var pendingAutoRecord = false
    @Published var pendingMemoID: UUID?

    func handle(url: URL) {
        guard url.scheme?.lowercased() == "tapnote" else { return }
        let host = (url.host ?? url.path).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if host == "record" || url.absoluteString.lowercased().contains("record") {
            markAutoRecord()
        }
        if host.hasPrefix("memo"), let id = UUID(uuidString: url.lastPathComponent) {
            pendingMemoID = id
        }
        // tapnote://memo/<uuid>
        if url.pathComponents.contains(where: { $0.lowercased() == "memo" }),
           let idString = url.pathComponents.last,
           let id = UUID(uuidString: idString) {
            pendingMemoID = id
        }
    }

    func consumePendingMemoID() -> UUID? {
        if let id = pendingMemoID {
            pendingMemoID = nil
            return id
        }
        if let raw = UserDefaults.standard.string(forKey: "tapnote.openMemoID"),
           let id = UUID(uuidString: raw) {
            UserDefaults.standard.removeObject(forKey: "tapnote.openMemoID")
            return id
        }
        return nil
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
