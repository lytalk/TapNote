# TapNote

Apple Watch + iPhone 一键语音速记。系统 Speech 转写 + 文件级 iCloud 同步；可选 OpenAI 兼容接口做总结。

## 要求

- macOS + **Xcode 16+**（建议与当前系统匹配的 Xcode 26.x）
- Apple Developer 账号（真机 / TestFlight / iCloud container）
- Bundle ID：`com.lytalk.TapNote`（Watch：`com.lytalk.TapNote.watchkitapp`）
- iCloud container：`iCloud.com.lytalk.TapNote`

## 打开工程

```bash
cd ~/Documents/watchrecord   # 或本仓库 clone 路径
# 若尚无 .xcodeproj：
brew install xcodegen && xcodegen generate
open TapNote.xcodeproj
```

在 Xcode 中为 **TapNote** / **TapNoteWatch** / **TapNoteWatchWidgets** 选择你的 Team，启用自动签名。

## Capabilities（需在开发者后台与 Xcode 对齐）

| Capability | iOS | watchOS |
|------------|-----|---------|
| iCloud (Cloud Documents) | ✓ | ✓ |
| Background Modes → Audio | ✓ | ✓ |
| Microphone | Info.plist | Info.plist |
| Speech Recognition | Info.plist | （可选） |

## 运行

1. Scheme 选 **TapNote**，先跑 iPhone 模拟器或真机。
2. 配对 Watch 模拟器或真机后，Watch app 会随 iOS 安装；亦可单独选 Watch scheme。
3. 表盘 Complication：添加 **TapNote 录音**（WidgetKit accessory）。
4. 首次录音会请求麦克风；转写会请求语音识别。默认语言 **zh-CN**。

```bash
# 有完整 Xcode 时：
xcodebuild -scheme TapNote -destination 'platform=iOS Simulator,name=iPhone 16' build
```

## 架构要点

- **共享模型** `Shared/Models/MemoRecording.swift`：id、title、createdAt、duration、audio path、recording/transcript/summary 状态与文本、updatedAt、iCloudRecordID。
- **同步**：文件级 iCloud Documents（非 CloudKit 记录）。音频 `Documents/audio/*.m4a` + 元数据 `Documents/meta/*.json`。冲突：**updatedAt last-writer-wins**，`AppLogger.sync` 记日志。
- **Watch → iPhone**：WatchConnectivity 文件传输 + 同一 iCloud 库双写。
- **AI（M4）**：设置里配置 Base URL / Key（Keychain）/ Model；可「仅 Wi-Fi」「仅手动」。无 Key 时隐藏 AI 区，录音与转写不受影响。

## 里程碑对照

| 里程碑 | 内容 |
|--------|------|
| M0 | 双 Target 脚手架 + 元数据 / 录音会话 |
| M1 | Watch 大按钮录音 + Complication；iPhone 库播放/删/改名；双端入库 |
| M2 | iCloud Documents + 系统 Speech 转写 |
| M3 | 首尾裁剪、分享音频/文稿、隐私文案、本 README |
| M4 | OpenAI 兼容总结设置 |

## 已知限制

- watchOS 后台熄屏续录受系统策略约束，尽量用 `audio` background mode；极端中断会标记状态提示。
- 本机若无 Xcode.app，无法在 CI/agent 上完成签名与模拟器验证。
