import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            LibraryView()
                .tabItem { Label("资料库", systemImage: "list.bullet") }
            RecordView()
                .tabItem { Label("录音", systemImage: "mic.circle.fill") }
            SettingsView()
                .tabItem { Label("设置", systemImage: "gearshape") }
        }
    }
}
