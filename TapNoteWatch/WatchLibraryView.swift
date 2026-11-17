import SwiftUI

struct WatchLibraryView: View {
    @EnvironmentObject private var library: MemoLibraryStore

    var body: some View {
        List {
            if library.memos.isEmpty {
                Text("暂无录音")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(library.memos.prefix(30)) { memo in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(memo.title)
                            .font(.headline)
                        Text("\(Formatters.durationString(memo.duration)) · \(memo.sourceDevice)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("资料库")
        .onAppear { library.reloadFromDisk() }
    }
}
