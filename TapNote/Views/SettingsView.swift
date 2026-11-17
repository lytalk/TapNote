import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var sync: ICloudDocumentSync
    @State private var baseURL = AISettings.current.baseURL
    @State private var model = AISettings.current.model
    @State private var apiKey = AISettings.current.apiKey ?? ""
    @State private var wifiOnly = AISettings.current.wifiOnly
    @State private var manualOnly = AISettings.current.manualOnly
    @State private var savedToast = false

    var body: some View {
        NavigationStack {
            Form {
                Section("同步") {
                    LabeledContent("iCloud", value: sync.statusText)
                    Text("策略：文件级 iCloud Documents；冲突以 updatedAt 较新者为准（LWW）并写日志。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("语音") {
                    Text("默认转写语言：zh-CN（系统 Speech）")
                        .font(.footnote)
                }

                Section("OpenAI 兼容接口") {
                    TextField("Base URL", text: $baseURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("API Key（存 Keychain）", text: $apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Model", text: $model)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Toggle("仅 Wi-Fi 时请求", isOn: $wifiOnly)
                    Toggle("仅手动触发总结", isOn: $manualOnly)
                    Button("保存 AI 设置") {
                        let settings = AISettings(
                            baseURL: baseURL,
                            model: model,
                            wifiOnly: wifiOnly,
                            manualOnly: manualOnly
                        )
                        settings.save(apiKey: apiKey)
                        savedToast = true
                    }
                    if apiKey.isEmpty {
                        Text("未配置 Key 时，录音与转写仍可用；AI 入口会隐藏。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("关于") {
                    LabeledContent("版本", value: "1.0 (M0–M4)")
                    Text("TapNote — Apple Watch + iPhone 语音速记")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("设置")
            .alert("已保存", isPresented: $savedToast) {
                Button("好", role: .cancel) {}
            }
        }
    }
}
