import SwiftUI

@main
struct TapNoteWatchApp: App {
    @StateObject private var library = MemoLibraryStore.shared
    @StateObject private var bridge = WatchBridge.shared
    @StateObject private var deepLink = DeepLinkRouter.shared

    var body: some Scene {
        WindowGroup {
            RecordWatchView()
                .environmentObject(library)
                .environmentObject(bridge)
                .environmentObject(deepLink)
                .onAppear {
                    deepLink.ingestLaunchArgumentsIfNeeded()
                    bridge.activate()
                    ICloudDocumentSync.shared.start()
                    SmokeHarness.runIfNeeded()
                }
                .onOpenURL { url in
                    deepLink.handle(url: url)
                }
        }
    }
}
