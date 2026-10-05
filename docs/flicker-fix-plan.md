# Plan: AI quilt 频闪治理（2026-10-04 录像分析固化）

> 附：docs/lyrics-and-peek-plan.md、docs/coreai-migration.md。

## 现象（用户录屏分析）

预览窗内 raymarch 基底为明亮粉彩方块城；扩散完成的 tile 是暗色夜景浮世绘街道。
录屏序列中 AI tile 在 quilt 网格上**随机位置逐个硬跳**出现/替换，与相邻 tile
明度/风格反差极大，形成「补丁式频闪」。

## 根因拆解

1. **硬切换**：worker 结果到达即整 tile 覆盖（updateTile 无淡入），
   每个 tile 每 ~0.7s 经历一次瞬时跳变。
2. **输入时间戳不一致**：逐视角在各自被调度的时刻渲染 staging（动画仍在走），
   一轮 56 视角的输入横跨 ~0.7s 动画相位，相邻 tile 几何/亮度相位差被扩散放大，
   tile 边界闪烁。
3. **风格/明度方差**：img2img 每视角独立（仅固定噪声+反馈约束），
   输出与输入明度差异大（暗色街道 vs 粉彩方块），跳变更刺眼。
4. **更新顺序**：中心优先轮询在屏幕上读作随机闪点（无空间连续性）。

## 修改方案（按见效排序）

### S1 — epoch 时间量化（消除输入时间差）
所有视角的 staging 渲染使用同一个 epoch 时间戳（`tEpoch = floor(sceneTime)`），
同一 epoch 内几何/亮度严格一致；epoch 间内容差被动画减速（timeScale 0.2）
压到很小。实现：dispatchView 用 epochTime 替代实时 time。

### S2 — tile 交叉淡入（消除硬切换）
新 tile 分 3 段淡入（alpha 0.4 / 0.75 / 1.0，间隔 ~120ms）：
`lkgTileBlitFS` 输出 alpha=blendAlpha，tileBlitPSO 开固定管线 blending
（srcAlpha / 1-srcAlpha，读改写同一纹理由 blending 硬件完成，合法）。
coordinator 在结果到达后排 3 次 updateTile。

### S3 — 同视角最小重扩散间隔
`lastDispatchAt[v]`，间隔 < 0.4s 不重复派发（防止单视角抖动被连续放大）。

### S4 — 时序粘合加强
worker `--feedback` 默认 0.15 → 0.3（latent 帧间混合比例）；DiffusionClient
透传 `--feedback` CLI 参数。

### S5 — 场景与风格明度对齐
新 synthwave 场景（地形+夕阳+星野）本身与 prompt（neon pastel）明度接近，
降低基底↔AI tile 的明度反差。后续可加 tile 明度归一（tileBlit 时把输出均值
拉到输入均值）作为兜底，暂记为备选。

### 验收
- 录像对比：同机位 10s 录屏，无可见随机闪点；epoch 间过渡柔和。
- 指标不回退：60 FPS / ≥50 tiles/s。
- `sq-demo --dump` md5 回归不变。

## 实施与验收记录（2026-10-04 完成）

- S1 epoch 时间量化：`dispatchView` 用 `floor(sceneTime())`，同 sweep 内输入同相位 ✓
- S2 三段交叉淡入（0.4/0.75/1.0 @ 0/120/240ms，fadeGen 代际防旧淡入覆盖新结果）✓
  实现要点：tileBlitPSO 开固定管线 blending（srcAlpha/1-srcAlpha，混合读改写同一纹理合法）；
  LKGTileBlitParams 加 blendAlpha。
- S3 同视角最小间隔 `minViewInterval = 0.4s` ✓
- S4 `--feedback` 透传，默认 0.15 → 0.3 ✓
- S5 新场景 synthwave terrain（fbm 高度场山谷 + 扫描线夕阳 + 星野 + 节拍冲击波环），
  音频四通道映射：bass→地形振幅/太阳大小，mid→相机摇摆/漂移速度，treble→星密度，
  beat→太阳闪光+地形冲击波环+天空脉冲。
  场景调试教训：raymarch 构图要算角尺寸（太阳半径 4.2@37 距离 = 半帧宽，改 2.1 才合适）；
  雾系数 0.0035 会淹没 15 单位外地形（改 0.0009）；pitch 0.14 会把地平线推到 60% 屏高（改 0.07）。
- 实机验收：60 FPS / 52 tiles/s / tile 0.94 Hz（场景 GPU 3.2ms，<预算）。

## 下一阶段（优先继续，2026-10-04 定）

当前版本已上线 S1–S5，实机待用户确认残余频闪形态。下一阶段按残余形态选招：

### N1 — tile 明度归一（兜底招，首选实施）
tileBlit 合成时把输出 tile 的明度均值拉到其输入（staging 快照）的明度均值：
worker 回传结果时附带输入帧的明度统计（或 Swift 侧算 staging 均值随任务传递），
shader 里乘归一系数。消除基底↔AI 的明度跳变，是残余「补丁感」的最大来源。

### N2 — 风格一致性加固
- 固定 per-view seed 不同会导致视角间风格漂移：尝试所有视角共享同一 latent 噪声
  （已是固定噪声 seed=42，但输入 latent 不同 → 输出仍漂）；评估把 strength 降到
  0.35–0.4 或用更具体的一致性 prompt（锁定 palette：explicit "bright pastel pink and
  cyan palette, sunset lighting"）。
- 每视角 latent feedback 目前 0.3，可 A/B 0.4/0.5 找拖影-频闪平衡点。

### N3 — 空间连续性更新顺序
中心优先轮询改为「逐行/逐列扫描波」顺序，让更新在视觉上是一列扫过的波
而不是散点；配合淡入可进一步降低察觉度。

### N4 — 节拍对齐的扩散节奏
BPM 已知时把 epoch 边界对齐到节拍（每 2 拍一个 epoch），让内容刷新本身合乐。

### 验收
同机位 30s 录屏对比（当前版 vs 新版）：无明显随机闪点/明度跳变；
60 FPS / ≥50 tiles/s 不回退；sq-demo --dump md5 回归。

## N1–N4 + 双 quilt lerp 实施记录（2026-10-04）

### N0 — 双 quilt 并行 + interlace 内 lerp（用户提出，新机制）
- 主 quilt = AI 合成层（基底 1/6 率 reprime + tile 覆盖）；alt quilt = 原始 raymarch
  层，mix 激活期间每帧渲染（+3.2ms GPU，预算内）。
- `lkgLenticularFS` 加 `altMix` uniform + texture(2) alt quilt：同一 q 坐标对两张
  quilt 各采一次逐子像素 mix（视角严格对齐，无重影）；mix≥0.999 时 FrameDriver
  直接换 source 省掉双采。
- G 键从 `displaySourceOverride` 硬切改为平滑推子：coordinator `peekMix` 按帧指数
  趋近（系数 0.12/frame，~0.5s 收敛）；`--alt-mix 0.15~0.25` 可设常驻混合地板，
  用始终新鲜的底层稀释 AI tile 跳变。预览窗 mix≥0.5 硬切（tonemap blit 无双采）。
- 接线：`LKGApp.altMixSource` provider；`encodeLenticular(alt:altMix:)`；
  `saveLenticularPNG` 透传。

### N1 — tile 明度归一 ✓
- Swift 侧在派发完成回调里算 staging RGB 的 Rec.601 均值存 `inputLuma[view]`；
  applyResult 算输出均值，gain = clamp(in/out, 0.5, 2.0)^strength，随三段淡入
  传给 `updateTile(lumaGain:)`；`lkgTileBlitFS` 在 pow(2.2) 前乘 gain（sRGB 域乘
  等价均值匹配）。lumaMean 每 4 像素抽样，CPU 开销可忽略。
- CLI `--luma-norm 0..1`（默认 1）；dump 路径同逻辑（离线输出与 live 一致）。

### N2 — 风格一致性 ✓（prompt 锁定；强度 A/B 后定案）
- 默认 prompt 换成 palette 锁定版，对齐 synthwave 场景：
  "synthwave retrowave landscape, bright pastel pink and cyan palette, golden sunset
  lighting, neon grid valley, starry sky, clean bold shapes, masterpiece"。
- strength A/B：0.45 / 0.40 / 0.35 dump 对比（见 /tmp/ai-new-s*.png）。
- feedback A/B（0.3/0.4/0.5）只能实机判断——dump 是单遍无帧间，feedback 不生效。

### N3 — 空间连续性更新顺序 ✓
- `ViewOrderMode.wave`（蛇形行扫描：底行起、奇行反向）为默认，`--order center`
  回退旧中心优先。配合淡入，更新读作一列扫过的波。

### N4 — 节拍对齐 epoch ✓
- `MusicBridge.beatClock` 暴露（相位拍数, 秒/拍）；coordinator `beatClockProvider`
  非 nil 时 epoch = floor(phase/2)*2*beatLen（每 2 拍一个 epoch），播放中生效；
  未播放/非 music 源回退 floor(sceneTime)。`--no-beat-epoch` 关闭。

### N5 — 消灭 10Hz 基底整屏擦写（隐藏频闪源，用户实机观察后定位）
原设计 `onFrame` 每 6 帧 `encodeBase`（loadAction=.dontCare）整屏覆盖主 quilt：
AI tile 淡入后活不过 ~0.1s 就被基底 re-prime **硬切**抹掉（截图里「大部分基底+
零星 AI 补丁」就是这个占空比）。淡入再柔，出口硬切等于白做。
修复：主 quilt 只在启动时打底一次，之后永不被整屏擦写；基底鲜活感改由
alt quilt（每帧渲）+ altMix lerp 提供。副产物：scene 时间从 3.1ms→0ms，
tiles/s 52→63。
**教训：持久合成层上任何全屏 dontCare pass 都是硬切频闪源。**

### N6 — AI 层节拍脉冲（显示级，用户反馈「AI 层对音效反应不明显」）
根因：每 tile 在各自派发时刻采样实时 audio uniform，beat 脉冲 exp 衰减
窗口只有 ~0.15 拍 → 56 tile 是 56 个随机相位的快照，空间上不连贯，
读作噪声而非节拍。且合成节拍钟是纯周期函数，epoch 对齐采样恒为常数，
「epoch 锁定 audio」对合成钟无解（对 mic 真音频才有意义）。
改在显示级做：interlace 加 `mainGain` uniform（仅乘主 quilt 采样，alt 层不动），
由与场景 uniform 同一个节拍钟 60Hz 驱动：`1 + beatGlow*beatPulse`，
默认 `--beat-glow 0.25`。整层随节拍平滑呼吸，与动画严格同相。
sq-demo 默认 1（c×1.0 位级不变，md5 回归已验）。
另：peek 期间 alt 层降为 1/2 帧率渲染（全速时 GPU 抢占会把 tiles/s 腰斩到 13）。

### 验收记录
- 构建通过；`sq-demo --dump` md5 回归不变（caaf1d42f528a58ecd3eeaede99aa554）。
- **euler strength no-op 修复**（streamdiffusion-mac pipelines/coreml.py）：sdxs 走
  euler 分支时 strength 被完全忽略（永远 t=999 全风格化）。修复后 t = t_max×strength；
  strength=1.0 dump md5 与修复前位级一致（7b4f1b59…），0.6/0.45/0.35 梯度生效。
  Pipeline 签名默认 strength 0.5→1.0（保持历史行为）。sq-ai-demo 默认 0.45→0.6。
- dump A/B：旧 prompt+无归一 = 暗色浮世绘城市 tile（与基底反差大）；新 prompt+归一
  = 亮粉彩 synthwave tile（太阳/网格/山谷构图与输入对齐，视角间一致）。
  强度对比：1.0 风格最强但偏离输入；0.45/0.35 被雾洗白；0.6 平衡（选定默认）。
- 实机（2026-10-04，M5 Max + LKG-E10707，2 worker 384²，音乐播放中 N4 生效）：
  60 FPS 锁定 / 52–64 tiles/s / tile 0.9–1.1 Hz / stale max 0.9s ✓ 不回退
  （N5 后 scene 0ms / post 1.1ms）。
