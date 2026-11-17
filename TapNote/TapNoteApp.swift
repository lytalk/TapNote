import SwiftUI

@main
struct TapNoteApp: App {
    @StateObject private var library = MemoLibraryStore.shared
    @StateObject private var sync = ICloudDocumentSync.shared
    @StateObject private var bridge = WatchBridge.shared
    @StateObject private var player = AudioPlayerService()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(library)
                .environmentObject(sync)
                .environmentObject(bridge)
                .environmentObject(player)
                .onAppear {
                    bridge.activate()
                    sync.start()
                }
        }
    }
}
