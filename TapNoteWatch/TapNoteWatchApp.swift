import SwiftUI

@main
struct TapNoteWatchApp: App {
    @StateObject private var library = MemoLibraryStore.shared
    @StateObject private var bridge = WatchBridge.shared

    var body: some Scene {
        WindowGroup {
            RecordWatchView()
                .environmentObject(library)
                .environmentObject(bridge)
                .onAppear {
                    bridge.activate()
                    ICloudDocumentSync.shared.start()
                }
                .onOpenURL { _ in
                    // Complication / deep link → already on record UI
                }
        }
    }
}
