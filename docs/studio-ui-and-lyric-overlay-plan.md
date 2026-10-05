# Plan: Studio UI 布局优化 + 视差歌词浮层（L2 接线）

> 2026-10-04。前置：docs/lyrics-and-peek-plan.md（L1/L3 已完成、L2 地基清单）、
> docs/emotion-prompt-plan.md（laya 引擎已接管 prompt）、skills/lkg-metal-quilt/SKILL.md。
>
> **状态：U1 + L2 已实现并离线验证**（构建过、dump md5 回归过、overlay-dump 目检过
> 方向/视差/中英日字体/分词换行）。实机目检（浮出方向 0.04 符号、60FPS/tiles/s 不回退）
> 待上机。超额完成项：满屏电影海报排版（scrim+header+footer 时间码）、
> CFStringTokenizer 分词换行 + 逐 token 中英/日字体、LyricFontPool 9 套字体池 +
> laya track-lane fontset 裁决、DiffusionClient pendingResults 内存泄漏修复。

## 背景与结论

- **歌词进度不能从 MusicKit 拿**。MusicKit 没有任何歌词 API（连普通歌词都
  不在 catalog 里，更无时间轴）；Apple Music 逐行歌词无公开接口。
  可行进度源（已在本仓库）：LRCLIB `syncedLyrics` 的行级 LRC 时间戳 +
  MusicBridge `position`（2s 轮询 + 外推）。行内进度 =
  `(position - lineStart) / (lineEnd - lineStart)`；逐词（word sync）只有
  LRCLIB `hasWordSync=true` 的曲目才有（稀少），不做。
- **浮层地基已入库（lyrics-and-peek-plan L2 地基）**：
  `LenticularUniforms.overlayShift/hasOverlay`、`lkgLenticularFS` texture(1)
  按视角视差采样 `ouv = (uv.x + (z-0.5)*overlayShift, 1-uv.y)`（tonemap 后
  alpha 混合）、`QuiltRenderer.encodeLenticular(..., overlay:overlayShift:)`。
- Studio 的设备显示走 **LKGDeviceWindowController**（不是 LKGApp）——
  overlay 参数要在它的 DeviceDriver cmd2 里接（新增 `overlayProvider` +
  `overlayShiftFraction`）。主屏预览走 tonemap blit（无 overlay 通道），
  浮层只在设备上可见。

## U1 — Studio UI 布局优化

现状：单列 VStack 堆所有控件，状态/传输/配置混在一起。改为分区卡片：

- 顶部状态条：FPS / tiles/s / tile Hz / workers ready + 🎭 情感 · 主题标签
  （现有 emotionLabel）+ Live prompt 回显（保持只读，已有）。
- `GroupBox("Playback")`：传输按钮 + now playing + 当前歌词行 + 行内进度条
  （ProgressView，值来自 L2 的行窗口）。
- `GroupBox("Audio & Style")`：audio source picker、Lyric prompts、
  Beat glow、Raw mix、歌词浮层开关（见 L2-3）。
- `GroupBox("Render")`：strength / render size / workers / grid + Apply。
- `GroupBox("Device")`：fullscreen、calibration test、bypass interlace。
- 错误行保留（红色 callout）。

## L2 — 视差歌词浮层（接线 + 渲染器）

1. **LyricOverlayRenderer（新，Sources/LKGQuilt/）**：
   - CoreText 把当前歌词行渲染进 RGBA8 纹理，尺寸 = 设备 drawable
     （1440×2560 × backingScale，运行时读 `view.drawableSize`，首帧惰性分配）。
   - 底部 1/4 居中面板，粗体白字黑边（stroke 描边用
     `NSStrokeWidthAttributeName` 负值 + `NSStrokeColorAttributeName`）。
   - **方向坑**：Metal 纹理 top-down、CGContext 底朝上——绘制前
     `translate(0,h) + scale(1,-1)` 翻转，先离线 dump 目检再上机。
   - 行变化才重绘整面板；行内进度条（面板底部 3pt 亮条）随 position
     每 ~0.25s 重绘一次（重绘成本 <1ms，勿每帧）。
   - 无词/纯音乐：显示曲名一行。
2. **行窗口 API**：LyricsService 加 `currentLineWindow(at:) ->
   (text: String, start: Double, end: Double)?`（当前行及其起止时间；
   末行 end = duration）。
3. **LKGDeviceWindowController 接线**：新增
   `overlayProvider: (() -> MTLTexture?)?` + `overlayShiftFraction: Float`
   （默认 0.04，符号决定凸出/凹进，上机目检后定案）；DeviceDriver cmd2
   传给 `encodeLenticular(overlay:overlayShift:)`。
4. **StudioModel**：持有 LyricOverlayRenderer，0.25s timer 喂当前行+进度；
   UI 加 "Lyric overlay" 开关（默认开，持久化）。
5. **lkg-ai-demo 同步接线**（LKGApp 同样加 overlayProvider；'l' 键开关），
   保持 CLI 端能力一致。

## 验收

- `swift build -c release` 全过；`lkg-demo --dump` md5 =
  caaf1d42f528a58ecd3eeaede99aa554 不变。
- 离线目检：`--dump-lentic`（lkg-ai-demo）能看到歌词条且逐视角有位移；
  方向正确（字不颠倒）。
- 实机：设备上歌词有浮出感、行切换跟词、进度条走字；60 FPS /
  ≥50 tiles/s 不回退（overlay pass 在 interlace 内，增量应 <0.5ms）。
- 起新实例前 `ps aux | grep lkg-` 清残留（多实例拖垮 display link）。

## 激活提示词（新 session 粘贴）

```
激活 lkg-metal-quilt 的 Studio UI + 视差歌词浮层子任务（U1 + L2）。

先读恢复上下文（本机）：
1. ~/Desktop/lkg-metal-quilt/docs/studio-ui-and-lyric-overlay-plan.md ← 本 plan
   （含 MusicKit 结论、overlay 地基清单、方向坑、验收标准）
2. ~/Desktop/lkg-metal-quilt/Sources/LKGQuilt/（地基位置：LKGFixedShaders 的
   overlay 采样、QuiltRenderer.encodeLenticular(overlay:overlayShift:)、
   LKGDeviceWindowController 的 DeviceDriver cmd2 是 Studio 接线点）
3. ~/.kimi-code/skills/lkg-metal-quilt/SKILL.md（全部踩坑：双 renderer 黑屏、
   多实例、print 块缓冲要用 pty、stableIndex 取模基数、laya sidecar 协议）

关键上下文：
- 歌词进度不从 MusicKit 拿（无歌词 API）；行进度 = LRCLIB LRC 行时间戳 +
  MusicBridge position 外推。LyricsService 需加 currentLineWindow(at:)。
- Studio 设备显示走 LKGDeviceWindowController（非 LKGApp），主屏预览无
  overlay 通道属预期。设备 drawable = 1440×2560 × backingScale（运行时读）。
- CGContext 画文字进 Metal 纹理要翻转 Y（先 dump 目检方向）。
- prompt 已由 laya 情感引擎接管（top-5 权重池 + 行情感），手动 prompt UI
  已移除；UI 优化只动布局，别动这条链路。
- 硬性约束：60FPS / ≥50 tiles/s 不回退；lkg-demo --dump md5 回归
  caaf1d42f528a58ecd3eeaede99aa554；live 模式 scene 必须用 app.renderer /
  宿主唯一 renderer；起新实例前清残留；git push 用
  env -u ALL_PROXY -u all_proxy git -c http.version=HTTP/1.1 push。
```
