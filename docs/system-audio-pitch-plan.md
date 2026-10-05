# Plan: 真实音频通道 + 音高检测（S5）

> 2026-10-05。前置：skills/streamquilt/SKILL.md、docs/scene-v4-plan.md（v4 已验收，
> commit 10cd966 已推送）。本 plan 解决两个相连的问题：合成节拍钟的律动上限
> （Apple Music PCM 有 DRM，MusicKit 拿不到音频流）与音高信息的获取。

## 现状与问题定位

| 现状 | 位置 | 局限 |
|---|---|---|
| 默认 `--audio-source music`：`MusicBridge.features` 由 BPM 元数据+位置外推合成 (bass,mid,treble,beat) | `Sources/StreamQuilt/AI/MusicBridge.swift:41`（已改 groove 引擎 v2：行走底鼓/反拍军鼓/16 分 hi-hat/8 拍乐句包络，**未提交**） | 合成图案再丰富也不是真音乐能量；无频谱、无音高 |
| `--audio-source mic`：`AudioAnalyzer` 真 FFT 频段能量 + 谱通量 beat | `Sources/StreamQuilt/AI/AudioAnalyzer.swift`（n=1024 tap，~43Hz 回调） | 听环境声而非直连；**无音高检测** |
| 情感引擎 hueBias 按曲目定色相锚 | TrackThemeEngine → scene.themeBias.x | 与音乐实际调性无关 |

## 方案：ScreenCaptureKit 系统音频 + 共享 DSP + 音高

macOS 13+ 的 ScreenCaptureKit 可以按应用捕获音频输出（不碰 DRM 文件本身，
捕获的是 Music.app 的播放输出）。这一条路同时解决真频谱律动和真音高。

### S5-1 共享 DSP（新文件 `Sources/StreamQuilt/AI/AudioDSP.swift`）

把 mic/system 两路收敛到同一条 DSP 管线：

- 2048 样本分析窗（43ms@48k，比 AudioAnalyzer 现有 1024 大一倍，80Hz 基频可检）；
  Hann 窗 → vDSP split-complex FFT。
- 频段能量 20–150 / 150–2k / 2k–8k Hz，自适应峰值归一（快攻慢放 0.995，沿用现参数）。
- 谱通量 beat（沿用：flux > 平滑×1.6 且 > 0.001 → beat=1 否则 ×0.88 衰减）。
- **PitchDetector（自相关基频）**：lag 范围 sampleRate/1200 … sampleRate/80
  （80–1200Hz），用 `vDSP_dotpr` 指针偏移做零拷贝部分自相关（禁每 lag 分配数组），
  按零延迟能量归一得置信度；抛物线插值补亚样本精度；`midi = 69 + 12·log2(f/440)`。
- **防跳变（N 系频闪教训适用）**：置信度 > 0.35 才更新；对连续 midi 做指数平滑
  （α≈0.25），输出 `pitchTurns = smoothedMidi/12`（音高类→色相 turn）；置信度低时
  保持上次值，**不回零**（回零 = 色相跳变）。
- 输出 `Output{bass,mid,treble,beat,pitchHz,pitchTurns,pitchConfidence}`，NSLock 保护。

`AudioAnalyzer`（mic）改为内部持有 AudioDSP（tap 回调直接喂样本），公共接口
`current` 扩字段，行为对调用点透明。

### S5-2 SystemAudioAnalyzer（新文件 `Sources/StreamQuilt/AI/SystemAudioAnalyzer.swift`）

- `SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)`
  → 找 `com.apple.Music`：`SCContentFilter(display:including:[music],...)`
  定向捕获；Music 未运行退回全系统混音（excludingApplications: []）。
- `SCStreamConfiguration`：`capturesAudio=true`、`excludesCurrentProcessAudio=true`、
  `sampleRate=48000`、`channelCount=1`、`width/height=2`、`minimumFrameInterval=1s`
  （最小视频开销）；`addStreamOutput(self, type: .audio)`，只挂 .audio。
- 音频 CMSampleBuffer → `CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer`，
  校验 ASBD 是 float32（不是则 print 警告并跳过）→ 喂 AudioDSP。
- **TCC**：需要「屏幕与系统音频录制」权限，CLI 裸二进制拿不到正常授权 —
  `CGPreflightScreenCaptureAccess()` 预检，缺失时 `CGRequestScreenCaptureAccess()`
  并 print 提示走 `.app` 路径（build_app.sh）。两个 Info.plist 加
  `NSScreenCaptureUsageDescription`（`Sources/sq-ai-demo/Info.plist`、
  `Sources/StreamQuiltApp/Info.plist`）。
- 生命周期同 worker 管理（SIGTERM/onWillTerminate 停 stream）。

### S5-3 接线（`Sources/sq-ai-demo/main.swift` + Studio）

- 新音源 `--audio-source system`。**元数据与音频解耦**：`music.start()`、
  N4 beatClock epoch、歌词/情感引擎 hook 在 music 和 system 模式下都跑
  （现在这些全在 `if cli.audioSource == "music"` 分支里，main.swift:318-368，
  需要把元数据部分提出来对 system 也生效），只是 `scene.audioProvider` 换成
  system 的真实特征；`beatForDisplay` 的 switch 加 system case。
- Studio：`AudioSourceKind` 加 `system`（label "System"），`applyAudioSource()`
  仿 music 分支接线（StudioModel.swift:419）。
- pitch 通道：`AIBlockCityScene` 加 `public var pitchProvider: (() -> Float)?`
  （默认 nil=0），`BaseParams`/`ViewParams` 尾部加 `var pitch: Float`；
  MSL `AIBaseParams`/`AIViewParams` 尾部加 `float pitch;`（尾部追加不影响对齐）。
- SceneShaders：`hueShift += pitch;`（音高类锚定色相，与情感引擎 theme.x 相加，
  一拍即合）；注释更新。mic 路径同样接 pitchProvider。

### S5-4 约束（沿用 N 系 + v4）

- epoch=floor(sceneTime)/beatClock 量化不动；AI tile 明度归一/交叉淡入链路不动。
- sq-demo 用独立 BlockCityScene，md5 基线 caaf1d42f528a58ecd3eeaede99aa554 必须不变
  （AudioDSP/SystemAudioAnalyzer 是新文件，SceneShaders 只加 pitch 一行，
  复跑 `--dump` 确认）。
- pitch 更新置信度门控 + 平滑，安静/噪声段保持上次值（防色相跳变）。
- 安静段落自主动运动（v4 相机漂移等）不受影响。

## 验收

- `swift build -c release` 过；sq-demo md5 不变。
- 离线回归：`sq-ai-demo --peek-dump`（audio=0 路径）画面与 v4 终版一致
  （pitch=0 时 hueShift 不变，位级可比）。
- 实机（需 .app 拿权限）：Music 播放时 `--audio-source system`，日志确认
  `[audio] system capture running` + pitch Hz 随曲目变化合理（流行歌主旋律
  ~200–600Hz）；场景律动跟随真鼓点（对比 music 合成模式的主观感受）；
  调色板随调性/音高区漂移。
- 权限弹窗只出现一次；拒绝时 print 提示且不崩（退回无声律动，画面仍动）。
- 60 FPS 不回退；SCK 2x2 视频流开销应可忽略（post ms 不显著涨）。

## 激活提示词（新 session 粘贴）

```
激活 StreamQuilt 的真实音频+音高改造（S5）。

先读恢复上下文（本机）：
1. ~/Desktop/StreamQuilt/docs/system-audio-pitch-plan.md ← 本 plan（问题定位 +
   AudioDSP/PitchDetector/SystemAudioAnalyzer 设计 + 接线 + 约束 + 验收）
2. ~/Desktop/StreamQuilt/Sources/StreamQuilt/AI/AudioAnalyzer.swift ← mic 路径现状
   （FFT 频段 + 谱通量 beat，要接 pitch）
3. ~/Desktop/StreamQuilt/Sources/sq-ai-demo/main.swift 318-375 ← audio-source 分支
   （music 分支里混着元数据/epoch/情感引擎 hook，system 模式要解耦）
4. ~/.kimi-code/skills/streamquilt/SKILL.md（N1–N6 频闪治理、TCC .app、多实例清理）

关键上下文：
- v4 已验收并推送（commit 10cd966）；工作区有未提交的 groove 引擎 v2
  （MusicBridge.features 重写：行走底鼓/反拍军鼓/16分 hi-hat/8拍乐句包络 +
  相机律动），build 和 md5 已验证过，继续在此基础上做。
- Apple Music PCM 是 DRM，音高/真频谱只能走 ScreenCaptureKit 应用音频捕获
  （不碰文件，捕获播放输出），TCC 需要屏幕与系统音频录制权限 + .app bundle。
- pitch 进 shader 走 AIBlockCityScene 新 pitchProvider + params 尾部 float pitch，
  hueShift += pitch（MIDI/12 turns）；置信度<0.35 保持上次值（防色相跳变）。
- 约束：epoch 量化不动；sq-demo md5 基线 caaf1d42f528a58ecd3eeaede99aa554 不变。
- 实机验收前 ps aux | grep -E "sq-|streamquilt" 清残留；
  push 用 env -u ALL_PROXY -u all_proxy git -c http.version=HTTP/1.1 push。
```
