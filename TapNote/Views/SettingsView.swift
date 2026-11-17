import SwiftUI
import WatchConnectivity

struct SettingsView: View {
    @EnvironmentObject private var sync: ICloudDocumentSync
    @EnvironmentObject private var bridge: WatchBridge

    var body: some View {
        NavigationStack {
            Form {
                Section("同步") {
                    LabeledContent("iCloud", value: sync.statusText)
                    if !sync.diagnosticDetail.isEmpty {
                        Text(sync.diagnosticDetail)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent(
                        "WatchConnectivity",
                        value: bridge.isReachable ? "手表可达" : "手表未可达 / 未连接"
                    )
                    LabeledContent(
                        "WCSession",
                        value: wcStateLabel(bridge.activationState)
                    )
                    if let msg = bridge.lastTransferMessage {
                        Text(msg)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Text("手表→手机不依赖 iCloud：优先 WatchConnectivity（sendMessage / transferFile）。同 Apple ID 且打开 iCloud 云盘时，还可走 iCloud Documents；冲突以 updatedAt 较新者为准。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("语音转写") {
                    Text("优先 iOS 26+ SpeechAnalyzer（端侧长语音模型，zh-CN）；失败时回退 SFSpeechRecognizer（优先 on-device）。多说话人标签由端侧频谱聚类生成（SDK 无官方 diarization）。手表录音同步到 iPhone 后自动转写。无云端 AI。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("关于") {
                    LabeledContent("版本", value: "1.0")
                    Text("TapNote — Apple Watch + iPhone 语音速记")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("设置")
            .onAppear { sync.refreshAvailability() }
        }
    }

    private func wcStateLabel(_ state: WCSessionActivationState) -> String {
        switch state {
        case .notActivated: return "未激活"
        case .inactive: return "未激活中"
        case .activated: return "已激活"
        @unknown default: return "未知"
        }
    }
}
