# Plan: SwiftUI 封装（StreamQuilt）

> 2026-10-04。把 StreamQuilt 从「CLI demo 集合」封装成真正的 SwiftUI macOS 应用。
> 前置上下文：仓库 README、docs/coreai-migration.md、skills/StreamQuilt/SKILL.md。

## 现状

- `StreamQuilt` 库（SwiftPM）：QuiltSpec / Calibration / QuiltRenderer / LKGApp（AppKit 外壳）。
- 可执行：`sq-demo`（纯 raymarch）、`sq-ai-demo`（StreamDiffusion AI quilt，
  CLI 参数 + 键盘控制 + stdout 状态行）。
- 已验证性能：7×8=56 布局、384²、异构双 worker → 显示 60 FPS + 77 tiles/s（tile ~1.4 Hz）。
- 音画互动：MusicBridge（Apple Music 节拍钟 + 播放控制）/ AudioAnalyzer（mic FFT）。

## 目标形态

**StreamQuilt.app**：控制面板 + 内嵌预览 + LKG 设备全屏管理，全部 SwiftUI。

```
┌─ StreamQuilt ─────────────────────────────┐
│ Prompt: [________________] [Apply]        │  ← 实时推给所有 worker
│ Style presets: [ukiyo-e ▾] [+保存当前]     │
│ Strength ──●── 0.45   Render size [384▾]  │
│ Workers [2]  Grid [7x8▾]  Audio [Music▾]  │
│ ┌──────────────┐  60 FPS · 77 tiles/s     │
│ │ quilt 预览    │  tile 1.4 Hz avg         │
│ │ (MTKView)    │  ♪ 曲名 — 艺人  ⏮⏯⏭      │
│ └──────────────┘  [设备全屏 ON] [校准测试] │
└────────────────────────────────────────────┘
```

## 执行步骤

### S0 — SPM 结构调整（不动现有行为）
1. 新 executable target `streamquilt`（SwiftUI app，macOS 14+）。
2. 从 sq-ai-demo 抽出可复用件进库或共享目录：`DiffusionClient`、`AIQuiltCoordinator`、
   `MusicBridge`、`AudioAnalyzer` 移到 `Sources/StreamQuilt/`（标注 public，CLI demo 继续编译通过
   —— 验收：`sq-demo --dump` 输出与迁移前 md5 一致）。
3. `LKGApp` 保留给 CLI；设备窗口管理抽成 `LKGDeviceWindowController`（库内 public），
   SwiftUI 和 AppKit 两条路径共用。

### S1 — StreamQuiltModel + 控制面板
1. `StreamQuiltModel: ObservableObject` 包住 renderer/client/coordinator/scene/music，
   @Published: prompt、strength、renderSize、workers、grid、audioSource、
   fps、tilesPerSec、tileHz、nowPlaying、playing。
2. Prompt Apply → `client.setPrompt()`（协议已有）；strength/renderSize 变化需重建 worker
   （terminate+respawn，~10s 加载）→ UI 显示 loading。
3. 播放控制按钮接 MusicBridge。

### S2 — 内嵌预览 + 设备窗口管理
1. `QuiltPreviewView: NSViewRepresentable` 包 MTKView（tonemap blit，30Hz）。
2. 「设备全屏」开关 → LKGDeviceWindowController.show/hide（LKG 屏无边框窗）。
3. 校准测试图、视差翻转等调试开关收进 Settings 页。

### S3 — 持久化
UserDefaults：最近 prompt 列表（下拉复用）、上次参数组合、窗口位置。

### S4 — 打包
`scripts/build_app.sh` 改为构建 StreamQuilt.app（Info.plist 已含 mic/automation 权限声明）；
图标（可用 flux-klein 生成）；可选 Developer ID 签名留空待用户决定。

### S5 — 回归
CLI 两个 demo 编译通过、`sq-demo --dump` md5 不变、AI 管线在 Studio 内达到同等
77 tiles/s 指标。

## 风险
- SwiftUI 生命周期与 Metal 渲染线程的桥接（用既有 LKGApp 帧循环，SwiftUI 只管 UI）。
- worker 重建的 UX（10s 黑屏提示）。
- 别碰 StreamQuilt 渲染热路径的线程模型（事件驱动调度已验证）。

## 激活提示词（新 session 粘贴用）

```
激活 StreamQuilt 的 SwiftUI 封装子任务（StreamQuilt）。

先读恢复上下文（本机）：
1. ~/Desktop/StreamQuilt/（README、Sources/、docs/swiftui-packaging-plan.md ← 本 plan、
   docs/coreai-migration.md）
2. ~/.kimi-code/skills/streamquilt/SKILL.md（全部踩坑：interlace 必须、Bridge PUT、
   事件驱动调度、ANE+GPU 异构、多实例性能杀手、TCC 要 app bundle 等）

目标与验收：按 docs/swiftui-packaging-plan.md 的 S0–S5 执行。
硬性约束：
- StreamQuilt 库只做 public 化扩展，不破坏 sq-demo / sq-ai-demo CLI（dump md5 回归）。
- AI 管线性能不回退：Studio 内也要 ~77 tiles/s + 60 FPS（7×8/384/异构 2 worker）。
- 设备全屏窗继续用 NSWindow 管理（SwiftUI 不管这个），控制面板与预览用 SwiftUI。
- 音频默认 Apple Music 联动（MusicBridge），mic 为可选源。
- git push 用 git -c http.version=HTTP/1.1。
```
