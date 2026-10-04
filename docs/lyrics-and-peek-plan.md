# Plan: 歌词视差浮层 + 歌词驱动 prompt（下次执行）

> 2026-10-04。前置：README、docs/coreai-migration.md、docs/swiftui-packaging-plan.md、
> skills/lkg-metal-quilt/SKILL.md。

## 已完成的前置（本仓库当前 HEAD）

- **G 键 peek**：按住 G 显示未加工的 raymarch shader（alt quilt 纹理 + 显示源切换），
  松开即复原，AI 后台持续无缝。**教训已修**：lkg-ai-demo 曾创建两个 QuiltRenderer
  （场景一个、LKGApp 一个）导致黑屏——live 模式必须用 `app.renderer` 建 scene。
- **浮层管线地基已打好（未接线）**：
  - `LenticularUniforms` 新增 `overlayShift` / `hasOverlay` 字段
  - `lkgLenticularFS` 已支持 overlay 纹理（texture(1)）+ 按视角亚像素视差偏移采样：
    `ouv = (uv.x + (z-0.5)*overlayShift, 1-uv.y)`，alpha 混合在 tonemap 之后
  - `QuiltRenderer.encodeLenticular(..., overlay:overlayShift:)` 参数就绪（nil=无浮层）

## 剩余任务

### L1 — 歌词获取与同步（LyricsService，放 Sources/lkg-ai-demo/）
1. 监听 MusicBridge 曲目变化（现有 line/duration/bpm/position 轮询 2s）。
2. 取词顺序：Music.app `lyrics of current track`（AppleScript，本地曲目有词时直接用）
   → 否则 LRCLIB `GET https://lrclib.net/api/get?artist_name=&track_name=&duration=`
   （本机直连已验证通）。LRCLIB 返回 `syncedLyrics`（LRC 格式）或 `plainLyrics`。
3. LRC 解析：`[mm:ss.xx]文本`（注意一行多时间戳），排序；`currentLine(at: position)`
   取最后一个 time <= position+0.2s 的行。无同步词时 plainLyrics 按行均分时长。
4. 纯音乐（instrumental）或无词：浮层显示曲名一行即可。

### L2 — 视差歌词浮层（LyricOverlayRenderer + 接线）
1. CoreText 把当前行渲染进 RGBA8 纹理（屏幕尺寸 1440×2560，底部 1/4 居中面板，
   粗体白字黑边；行变化才重绘）。注意 Metal 纹理 top-down 与 CGContext 的朝向，
   先用 `--peek-dump` 风格的离线 lentic dump 目检方向再上皮。
2. LKGApp 加 `overlayProvider: (() -> MTLTexture?)?` + `overlayShiftFraction`（默认 0.04，
   符号决定凸出/凹进，上机目检后定默认值），FrameDriver cmd2 传给 encodeLenticular。
3. 'l' 键开关歌词浮层（默认开）。
4. 验收：`--dump-lentic` 能看到歌词条且逐视角有位移；设备上歌词有浮出感且不影响
   60 FPS（浮层 pass 已在 interlace 内，增量 < 0.5ms）。

### L3 — 歌词调制 prompt
1. 行切换 → `client.setPrompt(base + ", " + 当前行前 60 字符)`（DiffusionClient.setPrompt
   已有协议）；节流 ≥2s、跳过空白行；BPM 已知时按节拍量化切换时机。
2. 加 `--lyric-prompt` / `--no-lyric-prompt` 开关（默认开），`--prompt` 作为 base。
3. 验收：两行歌词间 quilt 风格有可见语义漂移但不崩；tiles/s 不回退。

### L4 — 收尾
README 歌词章节、skill 追加、commit + push（HTTP/1.1）。

## 激活提示词（新 session 粘贴）

```
激活 lkg-metal-quilt 的歌词视差浮层子任务（L1–L4）。

先读恢复上下文（本机）：
1. ~/Desktop/lkg-metal-quilt/docs/lyrics-and-peek-plan.md ← 本 plan（含已完成的地基清单）
2. ~/Desktop/lkg-metal-quilt/README.md + Sources/（LKGQuilt 库的 overlay 地基已在：
   LenticularUniforms.overlayShift/hasOverlay、lkgLenticularFS 的 overlay 采样、
   encodeLenticular 的 overlay 参数）
3. ~/.kimi-code/skills/lkg-metal-quilt/SKILL.md（全部踩坑）

关键上下文：
- peek 功能已完成：按住 G 显示原始 shader（alt quilt），松开复原。
- 双 QuiltRenderer 黑屏教训：live 模式 scene 必须用 app.renderer 构建（库只有一个实例）。
- 歌词源：Music.app AppleScript lyrics 字段优先，LRCLIB（https://lrclib.net/api/get）
  兜底（本机直连可用）；同步靠 MusicBridge.position（2s 轮询 + 外推）。
- 音画互动现状：MusicBridge 节拍钟（BPM+position 合成）驱动 shader audio uniform；
  space/n/N 控制播放。
- 验收标准：L2/L3 跑完设备目检 + --dump-lentic 目检 + 60FPS/50+ tiles/s 不回退；
  lkg-demo --dump md5 回归不变。
- git push 用 git -c http.version=HTTP/1.1。
```
