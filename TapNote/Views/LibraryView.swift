import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var library: MemoLibraryStore
    @EnvironmentObject private var sync: ICloudDocumentSync
    @State private var renameTarget: MemoRecording?
    @State private var renameText = ""

    var body: some View {
        NavigationStack {
            Group {
                if library.memos.isEmpty {
                    ContentUnavailableView(
                        "还没有录音",
                        systemImage: "waveform",
                        description: Text("在手表或 iPhone 上开始第一段速记")
                    )
                } else {
                    List {
                        ForEach(library.memos) { memo in
                            NavigationLink(value: memo.id) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(memo.title)
                                        .font(.headline)
                                    HStack {
                                        Text(Formatters.listDate.string(from: memo.createdAt))
                                        Text("·")
                                        Text(Formatters.durationString(memo.duration))
                                        if memo.transcriptStatus == .completed {
                                            Image(systemName: "text.alignleft")
                                        }
                                    }
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                }
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    library.delete(id: memo.id)
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                            }
                            .swipeActions(edge: .leading) {
                                Button {
                                    renameTarget = memo
                                    renameText = memo.title
                                } label: {
                                    Label("重命名", systemImage: "pencil")
                                }
                                .tint(.orange)
                            }
                        }
                    }
                    .navigationDestination(for: UUID.self) { id in
                        if let memo = library.memo(id: id) {
                            MemoDetailView(memoID: memo.id)
                        }
                    }
                }
            }
            .navigationTitle("TapNote")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        library.reloadFromDisk()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Text(sync.statusText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 4)
            }
            .alert("重命名", isPresented: Binding(
                get: { renameTarget != nil },
                set: { if !$0 { renameTarget = nil } }
            )) {
                TextField("标题", text: $renameText)
                Button("保存") {
                    if let id = renameTarget?.id {
                        library.rename(id: id, title: renameText)
                    }
                    renameTarget = nil
                }
                Button("取消", role: .cancel) { renameTarget = nil }
            }
        }
    }
}
