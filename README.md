# TapNote

Apple Watch + iPhone 一键语音速记。系统 Speech 转写；手表→手机走 WatchConnectivity；可选同账号 iCloud Documents。

## 要求

- macOS + **Xcode 16+**（建议与当前系统匹配的 Xcode）
- Apple Developer 账号（真机 / TestFlight / iCloud container）
- Bundle ID：`com.lytalk.TapNote`（Watch：`com.lytalk.TapNote.watchkitapp`）
- iCloud container：`iCloud.com.lytalk.TapNote`（可选；模拟器未登录 Apple ID 时会回退本机库）

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
| Speech Recognition | Info.plist | — |

## 运行

1. Scheme 选 **TapNote**，先跑 iPhone 模拟器或真机。
2. 配对 Watch 模拟器或真机后，Watch app 会随 iOS 安装；亦可单独选 Watch scheme。
3. 表盘 Complication：添加 **TapNote 录音**（WidgetKit accessory）。
4. 首次录音会请求麦克风；转写会请求语音识别。默认语言 **zh-CN**。

### 模拟器 iCloud 不可用时

模拟器默认没有 Apple ID：`ubiquityIdentityToken` 为 nil，设置页会显示「iCloud 未登录（使用本机库）」。

1. 打开 **DeviceHub / Simulator** 里已启动的 iPhone。
2. 打开 **设置 → 顶部 Apple ID 登录**。
3. 进入 **iCloud → 打开 iCloud 云盘**。
4. 重新启动 TapNote；设置页应变为「iCloud Documents 已启用」。

**手表录音不会卡在手表上**：即使未登录 iCloud，停录后也会经 WatchConnectivity（`sendMessage` + `transferUserInfo` / `transferFile`）传到 iPhone 资料库。

```bash
xcodebuild -scheme TapNote -destination 'platform=iOS Simulator,name=iPhone Air' build
```

## 架构要点

- **共享模型** `Shared/Models/MemoRecording.swift`：id、title、createdAt、duration、audio path、recording/transcript 状态与文本、updatedAt、iCloudRecordID。
- **Watch → iPhone（必需路径）**：WatchConnectivity — 可达时 `sendMessage` 直传 memo+音频；并排队 `transferUserInfo` / `transferFile`。不依赖 iCloud。
- **iCloud（可选）**：文件级 Documents（非 CloudKit）。音频 `Documents/audio/*.m4a` + 元数据 `Documents/meta/*.json`。冲突：**updatedAt last-writer-wins**。
- **转写**：仅 iOS 系统 Speech（zh-CN）；手表录音入库后自动转写。无第三方 AI 总结 UI。

## 里程碑对照

| 里程碑 | 内容 |
|--------|------|
| M0 | 双 Target 脚手架 + 元数据 / 录音会话 |
| M1 | Watch 大按钮录音 + Complication；iPhone 库播放/删/改名；双端入库 |
| M2 | iCloud Documents + 系统 Speech 转写 |
| M3 | 首尾裁剪、分享音频/文稿、隐私文案、本 README |
| M4 | （已撤回 UI）OpenAI 兼容总结代码保留但设置页不展示 |

## 已知限制

- watchOS 后台熄屏续录受系统策略约束，尽量用 `audio` background mode；极端中断会标记状态提示。
- 模拟器未登录 Apple ID 时 iCloud 不可用属预期；同步请用 WatchConnectivity。
