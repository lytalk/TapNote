import SwiftUI

@main
struct TapNoteApp: App {
    @StateObject private var library = MemoLibraryStore.shared
    @StateObject private var sync = ICloudDocumentSync.shared
    @StateObject private var bridge = WatchBridge.shared
    @StateObject private var player = AudioPlayerService()
    @StateObject private var deepLink = DeepLinkRouter.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(library)
                .environmentObject(sync)
                .environmentObject(bridge)
                .environmentObject(player)
                .environmentObject(deepLink)
                .onAppear {
                    bridge.activate()
                    sync.start()
                    SmokeHarness.runIfNeeded()
                }
                .onOpenURL { url in
                    deepLink.handle(url: url)
                }
        }
    }
}
