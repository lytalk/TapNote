import SwiftUI

struct TrimView: View {
    let memoID: UUID
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: MemoLibraryStore
    @State private var head: Double = 0
    @State private var tail: Double = 0
    @State private var busy = false
    @State private var errorText: String?

    private var memo: MemoRecording? { library.memo(id: memoID) }

    var body: some View {
        NavigationStack {
            Form {
                if let memo {
                    Section("裁剪（秒）") {
                        Stepper(value: $head, in: 0...(max(0, memo.duration - 0.5)), step: 0.5) {
                            Text("开头去掉 \(String(format: "%.1f", head)) 秒")
                        }
                        Stepper(value: $tail, in: 0...(max(0, memo.duration - 0.5)), step: 0.5) {
                            Text("结尾去掉 \(String(format: "%.1f", tail)) 秒")
                        }
                        Text("结果约 \(Formatters.durationString(max(0.1, memo.duration - head - tail)))")
                            .foregroundStyle(.secondary)
                    }
                }
                if let errorText {
                    Text(errorText).foregroundStyle(.red)
                }
            }
            .navigationTitle("简易裁剪")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("应用") {
                        Task { await apply() }
                    }
                    .disabled(busy)
                }
            }
        }
    }

    private func apply() async {
        busy = true
        defer { busy = false }
        do {
            try await AudioTrimService.trim(memoID: memoID, headSeconds: head, tailSeconds: tail)
            dismiss()
        } catch {
            errorText = error.localizedDescription
        }
    }
}
