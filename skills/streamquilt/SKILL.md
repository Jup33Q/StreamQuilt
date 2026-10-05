---
name: streamquilt
description: >
  用 Swift + Metal 为 Looking Glass 光场显示器（LKG Go 等）做实时 quilt 渲染的本地库与 demo。
  当用户要「Metal 实时渲染到 LKG / Looking Glass」「实时 quilt」「光场显示器渲染管线」
  「柱镜 interlace / lenticular 交织」「从 Bridge 取校准参数」「streamquilt 项目」
  「给 LKG Go 写原生 app」时使用。仓库：https://github.com/Jup33Q/streamquilt
  本地路径：~/Desktop/StreamQuilt
---

# streamquilt — Metal 实时 quilt 渲染

Swift + Metal 的 Looking Glass 实时渲染管线（真机验证：LKG Go / LKG-E10707 + M5 Max，
4092×4092 全分辨率 66 视角，稳定 60 FPS）。纯 SwiftPM 包，无需 Xcode（shader 运行时编译）。

- 仓库：https://github.com/Jup33Q/streamquilt
- 本地：`~/Desktop/StreamQuilt`（`swift run -c release sq-demo` 即跑）

## 核心原理（踩坑固化）

**LKG 上屏的不是 quilt 本身**。quilt 只是 N 个视角的容器；上屏前必须做
「Looking Glass 光学变换」——按设备出厂校准参数（pitch/slope/center/DPI）把 quilt
按 RGB 子像素交织成 lenticular 图像。直接把 quilt 全屏显示只会看到格子。
交织 shader 移植自官方 holoplay.js 的 `QUILT_FRAGMENT_SHADER`（见库内
`LKGFixedShaders.swift`），校准参数推导：

```
pitch' = pitch * (screenW/DPI) * cos(atan(1/slope))
tilt'  = screenH / (screenW * slope)   (flipImageX=1 时取负)
subp   = 1 / (screenW * 3)
```

**校准从 Looking Glass Bridge REST API 实时获取**（Bridge 必须运行）：
`PUT localhost:33334/enter_orchestration` body `{"name":"xxx"}` → 拿 token →
`PUT /available_output_devices` body `{"orchestration":token}` →
遍历设备找 hwid 含 "LKG" 的，calibration 字段是内嵌 JSON 字符串。
GET 请求会拿到空 200，**必须 PUT**。注意本机 shell 有代理环境变量时 Python
websockets/requests 会被 SOCKS 拦，加 `proxy=None` 或 `env -u ALL_PROXY`。

**Quilt 约定**：view 0 = 左下角 tile，行优先从左到右、从下到上扫；Metal 纹理 v 向下，
interlace shader 里要翻 v。相机是平行离轴阵列（焦点平面 z=0 在所有视角投影一致），
raymarch 场景直接用库的 `LKGShaderCommon.msl`（`lkgTileInfo` / `lkgViewOffset` /
`lkgViewRay`）；mesh 场景用 `QuiltCamera` 的逐视角离轴投影矩阵。

**视角数按设备实测规格**：LKG Go = 11×6=66（4092²，tile 372×682，a0.56）——
Bridge 的 `defaultQuilt` 字段会返回当前设备的默认规格，以它为准。

## 使用方法

### 跑 demo（方块城市 raymarch 场景）

```sh
cd ~/Desktop/StreamQuilt
swift run -c release sq-demo                  # LKG 全屏 + 主屏预览窗
swift run -c release sq-demo -- --no-preview  # 只上设备
```

按键（先点预览窗聚焦）：q 退出 · s/S 存 quilt/交织 PNG · f 视差反向（画面内翻时用）·
`-=` 视差幅度 · `[]` 相机距离 · `90` FOV · 1/2 全/半分辨率 · p 暂停 ·
b 绕过 interlace 显示裸 quilt · c 校准测试图（每视角纯色：对齐正确时整屏单色、
转头颜色连续变化；有彩虹纹=校准错位）。

离线出图（QuiltPlayer 兼容命名）：`sq-demo -- --dump out_qs11x6a0.56.png --time 1.2`，
交织图 `--dump-lentic lentic.png`。

### 作为库集成

```swift
.package(url: "https://github.com/Jup33Q/streamquilt.git", from: "0.1.0")
```

```swift
import LKGQuilt
let app = try LKGApp(spec: .lkgGo)   // 自动找 LKG 屏幕 + 从 Bridge 拉校准
app.onRenderQuilt = { cmd, pass, time in /* 把场景编码进 quilt pass */ }
app.onKey = { key in false }
app.run()
```

自定义 raymarch 场景：shader 源码前拼 `LKGShaderCommon.msl`，fragment 里画全屏三角形、
用 `lkgTileInfo(fpos.xy, tileSize, cols, rows)` 定位视角。完整范例：
`Sources/sq-demo/BlockCityScene.swift`。

## 性能参考（M5 Max）

| 阶段 | GPU 耗时 |
|---|---|
| 场景 raymarch（66 视角 4092²） | ~9 ms |
| interlace（1440×2560） | 亚毫秒级 |
| 总帧率 | 60 FPS（vsync 锁定） |

性能坑：interlace 会从 64MB fp16 quilt 纹理散射采样，别把 quilt 拷来拷去；
预览窗限 30Hz（否则主屏 120Hz 的 blit 会抢 GPU）。GPU 计时注意
`gpuStartTime/EndTime` 包含 vsync 等待，测量要拆 command buffer。

## AI quilt 管线（sq-ai-demo，2026-10-04 实测固化）

逐视角 StreamDiffusion 风格化实时上屏。架构：Metal raymarch 逐视角 384² staging →
Python worker 池（CoreML SDXS img2img）→ 区域拼回持久化 quilt → interlace 60Hz。
**事件驱动是关键**：worker 完成一个 tile 立即触发下一个视角渲染+派发（结果回调自持续），
不要挂在 display link 上（LKG 屏的 MTKView display link 会被拖慢到 ~2.7Hz，原因未明，
解耦后完全不受影响）。

实测数据（M5 Max）：
- 单 worker 512²：25ms/帧（40 img/s）；384² 异构双 worker：90 tiles/s（bench）/
  77 tiles/s（实机），每视角均刷新 ~1.4 Hz（7×8=56 布局全扫 0.7s）。
- **并发正确姿势是 ANE+GPU 异构**（worker0=all，其余=cpu_and_gpu）：双 ANE 时分复用
  只有 19 tiles/s。batch UNet（b4）ANE/GPU 都更慢（~50ms/view），已转换留档勿默认。
- 7×8=56 布局（`QuiltSpec.lkgGo56`，tile 288×512，quilt 2016×4096）比 66 省 15% 视角
  +31% 像素，tile 宽高比 0.5625 与屏幕精确一致。
- 指标看**单 tile 平均刷新率**（tiles/s ÷ viewCount），别看整屏 FPS（永远 60）。

Python worker 踩坑（python/quilt_diffusion_worker.py）：
- Pipeline init 会往 stdout 打印 → 用 dup2 把 fd1 临时重定向到 stderr，否则协议流被污染。
- `threading.current_thread().ident` 可能 >2^32 → 打包前 & 0xFFFFFFFF。
- venv 用 `.venv/bin/python -m pip`（无 pip 可执行文件）；PyPI 直连超时，用阿里/清华镜像；
  HF 直连超时，用 `HF_HUB_OFFLINE=1` + 本地 snapshot。
- macOS 27 会把老 scipy wheel 干废（__thread_bss 报错）→ `pip install -U scipy` 升级修复。
- 非 512 分辨率要在 MODEL_CONFIGS 注入 unet_prefix（worker 已自动处理 384 等）。
- 逐视角 latent feedback：worker 按 view 换存 `_prev_denoised`（防串视角污染）；
  固定 seed 噪声保证 66 视角风格一致。

Swift 侧踩坑：
- `Data.removeFirst` 后下标不从 0 开始 → `copyBytes(from:)` 必须用 startIndex 相对偏移
  （否则 EXC_BREAKPOINT）。
- Swift `signal()` 回调不能捕获上下文 → 用全局变量持有 client。
- CoreML predict 返回的 MLMultiArray 是池化复用的，读结果要立刻拷贝。
- Swift 加载 .mlpackage 需先 `MLModel.compileModel` → .mlmodelc。
- 结束进程要清理 python worker：TaskStop/杀 bash 会留孤儿占 ANE/GPU（SIGTERM 处理 +
  onWillTerminate 双保险）。

CoreAI 迁移侦察结论见 docs/coreai-migration.md（coreai-torch 转 .aimodel ✓，
Swift CoreAIRuntime 加载 ✓，NDArray 支持 MTLBuffer 零拷贝）。

## 文件地图

- `Sources/LKGQuilt/QuiltSpec.swift` — quilt 网格规格（.lkgGo / .lkgPortrait / 自定义）
- `Sources/LKGQuilt/Calibration.swift` — 校准模型 + Bridge REST 拉取 + 内嵌回退值
- `Sources/LKGQuilt/QuiltRenderer.swift` — HDR quilt 目标 + tonemap/interlace/测试图 pass + PNG 导出
- `Sources/LKGQuilt/LKGApp.swift` — AppKit 外壳（LKG 全屏窗 + 预览窗 + 按键 + 帧循环）
- `Sources/LKGQuilt/LKGShaderCommon.swift` — 场景 shader 公共 prelude（tile 数学）
- `Sources/LKGQuilt/LKGFixedShaders.swift` — interlace/tonemap shader（运行时编译）
- `Sources/LKGQuilt/QuiltMath.swift` — mesh 内容的离轴相机矩阵
- `Sources/sq-demo/` — 方块城市 demo 场景
- `Sources/sq-ai-demo/` — AI 风格化 demo（DiffusionClient worker 池 + AIQuiltCoordinator
  事件驱动调度 + AIBlockCityScene 逐视角渲染）
- `python/quilt_diffusion_worker.py` — StreamDiffusion 逐视角 worker（协议见文件头注释）
- `python/bench_coreml_pipeline.py` / `bench_concurrent.py` / `bench_batch.py` — 基准工具
- `scripts/convert_unet_coreml.py` — 离线 UNet→CoreML 转换（支持本地 snapshot 与 --batch）
- `scripts/coreml_spike.swift` — 纯 Swift+CoreML img2img 链路验证
- `scripts/coreai_smoke_test.py` — coreai-torch 转换 + coreai.runtime 加载验证
- `docs/coreai-migration.md` — CoreAI/CoreML Swift 迁移可行性备忘录

## 音画互动（2026-10-04 固化）

- **Apple Music PCM 是 DRM 保护的，MusicKit 拿不到音频流**。联动走 Music.app AppleScript：
  Now Playing 元数据（曲名/艺人/BPM 字段）+ 播放器位置外推 → 合成节拍钟驱动 shader
  uniform（bass/mid/treble/beat）。控制键：space 播放暂停 / n 下一首 / N 上一首。
  真音频分析走 `--audio-source mic`（AVAudioEngine+vDSP FFT，需 .app bundle 拿 TCC 权限：
  `bash scripts/build_app.sh`）。
- AppleScript 多行字符串里换行续接是 `¬` 不是 `\`（`\` 会语法错误，静默拿不到数据）。
- **多实例是性能杀手**：多个 app 实例在同一块 LKG 屏各开无边框窗会把 display link
  拖到 ~2.7Hz。起新实例前 `ps aux | grep sq-ai-demo` 清干净；TaskStop 只杀 bash 壳，
  Swift 进程要用 exec 直挂或显式 kill。

## laya 情感引擎（2026-10-04 固化，docs/emotion-prompt-plan.md E1–E3）

- **laya 概率在 `r["answers"][q]["probabilities"]`（每个 answer 内）**，顶层
  `r["probabilities"]` 不存在。sidecar `python/laya_emotion_worker.py` 已拍平。
- sidecar 协议卫生：启动时 dup fd1 → dup2(2,1)，协议帧用私有 fd os.write，
  第三方库杂散 print 永不污染 stdout。
- **hash 兜底是同步完成的，`inFlightTrackID` 必须在兜底路径清掉**，否则
  laya ready 后的重分类被 in-flight 守卫永久挡住。
- **stableIndex 取模基数必须跟着目标表走**（Emotion.all=14 vs Theme.all=12，
  共用 14 取模会在 hash 命中 12/13 时越界 SIGTRAP 崩在主线程）——签名带
  `modulo:` 参数强制调用点显式给。
- GUI app 的 print 写管道是块缓冲（日志不出）；`script -q` 在 agent shell 报
  "tcgetattr on socket" → 用 `python3 -c 'import pty; pty.spawn(...)'` 拿行缓冲实时日志。
- 逐行 laya 走 ANE 96 token 车道：歌词行截 40 字符 + 短指令；整曲走 1024 车道。
  prompt 契约 = 采样主题 + 行情感 + 歌词行 + 固定质量尾（`Theme.qualityTail`）。
- Studio G 键 peek：NSEvent local monitor（keyCode 5），文本框聚焦放行，
  handled return nil 防 beep。

## G 键 peek 与浮层地基（2026-10-04 固化）

- 按住 G = 平滑淡入原始 raymarch 层（双 quilt lerp，见下节），松开淡回；
  退出是 Cmd+Q（q 已让位）。库侧：QuiltRenderer.altQuiltTexture /
  makeAltQuiltPassDescriptor / encodeLenticular(source:overlay:overlayShift:alt:altMix:)。
  旧 displaySourceOverride 硬切保留为 API，AI demo 已改用 altMixSource。
- **双 QuiltRenderer 黑屏教训**：LKGApp 自建 renderer；live 模式场景必须用
  `app.renderer` 构建，否则场景渲进A纹理、屏幕读B纹理=黑屏。sq-ai-demo 曾中招。
- 歌词浮层地基（overlayShift/hasOverlay + interlace 内视差采样）已入库未接线，
  续作见 docs/lyrics-and-peek-plan.md。
- 调试技巧：LKG_PEEK_TEST=1 环境变量可让 app 自动进 peek 并落盘 interlace PNG，
  无需手动按键即可验证显示路径。

## 歌词浮层 L2 实装（2026-10-04 固化）

- **DiffusionClient pendingResults 内存泄漏**：live 模式走 onResult 回调、从没人调
  drainResults → 每个 tile 的 RGBA Data 永久堆积（45 分钟会话 117k 个 buffer，
  写入 ~147GB、52.9GB 被 swap，活动监视器显示 65GB+）。修复：onResult != nil 时
  不进 pendingResults。诊断手法：heap -sortBySize 看 `__DataStorage._bytes`。
- **CLI 进程里 NSString.draw 静默 no-op**：没有 NSGraphicsContext.current。
  必须 `NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)`。
- **NSShadow attribute 会吃掉白字填充**（DINCondensed 上白色覆盖掉 60%）——
  浮层不用 shadow，只用负 strokeWidth 描边。
- **字体 cascadeList 出来的中文是细字重**：改成逐 token 指定字体。
  分词用系统 CFStringTokenizer（kCFStringTokenizerUnitWord，真词边界，中英混排一次过，
  不要为这去上 CoreML 模型）；闭合标点禁行首（kinsoku）表在 LyricOverlayRenderer。
- 假名检测（0x3040-0x30FF）切换 zh/ja 字体；日文字体：HiraginoSans-W6~W9（哥特）、
  YuMin-Demibold/Extrabold、HiraMinProN-W6（明朝）。
- 字体池 LyricFontPool（9 套，含 strokeFactor：书法/手写体 0.015-0.02，粗体 0.03）；
  laya 在 track lane（1024 token）随 theme/emotion 同请求裁决 fontset 问题
  （**96 token 的 ANE line lane 放不下 criteria 列表**），答案非法/ollama/未就绪时
  stableIndex("font:"+id, modulo: LyricFontPool.all.count) 哈希兜底。
- Cinzel（Trajan 平替，OFL）装在 ~/Library/Fonts/Cinzel-Variable.ttf，
  PostScript 名 CinzelRoman-Bold/Black。
- 离线目检：`sq-ai-demo --overlay-dump x.png [--font-set id] [--overlay-text "..."]`，
  同时输出 x-overlay.png（裸纹理，查方向/字体）。
- 浮层接线：LKGApp/LKGDeviceWindowController 的 overlayProvider+overlayShiftFraction
  （默认 0.04）；Studio 0.25s timer 喂行窗口+进度+时间码，sq-ai-demo 'l' 键开关。

## 频闪治理与新场景（2026-10-04 固化，docs/flicker-fix-plan.md）

- AI tile 频闪四根因：硬切换 / 输入时间戳不一致 / 风格明度方差 / 更新顺序随机感。
  对应：三段交叉淡入（tileBlitPSO blending）+ epoch 时间量化（floor(sceneTime)）+
  同视角最小间隔 0.4s + feedback 0.3 + 场景风格明度对齐。
- raymarch 构图速算：fov 25° 时 ndc 半宽 0.22，物体角半径 asin(r/dist) 超它就超半帧；
  雾系数 >0.002 会淹没中景；预览 dump 看构图先出 -quilt.png 别看 interlace 图。

## 频闪 N1–N4 + 双 quilt lerp（2026-10-04 固化）

- **双 quilt lerp（N0）**：主 quilt=AI 合成层、alt quilt=原始 raymarch 层并行；
  interlace shader 内同一 q 坐标双采逐子像素 mix（`LenticularUniforms.altMix` +
  texture(2)，视角严格对齐无重影）。G 键=平滑推子（peekMix 指数趋近 0.12/frame），
  `--alt-mix` 设常驻混合地板。mix≥0.999 时 FrameDriver 直接换 source 省双采；
  预览窗 mix≥0.5 硬切（tonemap blit 无双采）。接线：LKGApp.altMixSource。
- **N1 明度归一**：派发回调算输入 RGB 的 Rec.601 均值存 inputLuma[view]，
  applyResult 算输出均值，gain=clamp(in/out,0.5,2)^strength 随淡入传 updateTile；
  lkgTileBlitFS 在 pow(2.2) 前乘 gain（sRGB 域乘=均值匹配）。`--luma-norm` 默认 1。
- **N2 大坑：sdxs 走 euler 分支时 --strength 一直是 no-op**（永远 t=999）！
  修复 streamdiffusion-mac coreml.py：t=t_max×strength，签名默认 0.5→1.0 保历史行为；
  strength=1.0 dump md5 与修复前位级一致做回归。sq-ai-demo 默认改 0.6
  （0.45/0.35 被雾洗白；1.0 风格强但跳变大）。palette 锁定 prompt 对齐场景。
- **N3 更新顺序**：ViewOrderMode.wave 蛇形行扫描（底行起奇行反向）为默认，
  --order center 回退。**N4**：MusicBridge.beatClock → epoch=floor(phase/2)×2×beatLen
  （每 2 拍一个 epoch），未播放回退 1s wall epoch；--no-beat-epoch 关。
- **N5 隐藏频闪源**：onFrame 每 6 帧 encodeBase 整屏 dontCare 覆盖主 quilt =
  AI tile 淡入后 ~0.1s 被硬切抹掉（截图占空比可证）。持久合成层上任何全屏
  dontCare pass 都是硬切频闪源 → 主 quilt 只启动时打底一次，鲜活感走 altMix。
- **N6 AI 层节拍反应弱**：tile 在各自派发时刻采实时 audio uniform = 56 个随机
  相位快照（beat 脉冲窗只有 ~0.15 拍），空间不连贯读作噪声；合成节拍钟是纯周期
  函数，「epoch 锁定 audio」恒为常数无解。正解是显示级：interlace mainGain
  uniform（仅乘主 quilt），由同一节拍钟 60Hz 驱动 1+0.25×beatPulse（--beat-glow）。
  sq-demo 默认 1 位级不变。peek 期间 alt 层 1/2 帧率渲（全速会把 tiles/s 腰斩）。
- **歌词驱动 prompt（L1/L3）**：LyricsService = Music.app AppleScript
  `lyrics of current track`（纯文本）→ LRCLIB /api/get 兜底（带 UA、URLSession+信号量、
  后台线程）；LRC 一行多时间戳要逐个展开；plainLyrics 按时长均分。行切换 →
  setPrompt(base+行前60字符)，节流 2s + 对齐下一节拍边界。CLIP 对中文歌词覆盖弱，
  中文曲目后续做关键词→英文映射。L2 视差歌词浮层地基（overlayShift）仍未接线。
- **G 推子过渡中点（mix≈0.5）光栅会短暂失焦**：AI tile 是方形 staging 居中裁切，
  与 alt 层直接按 tile 宽高比渲染的构图有微差 + AI tile 最多 ~1s 陈旧，双层混合时
  视差失配——属过渡预期；预览窗 mix≥0.5 硬切到 alt quilt（预览永不 interlace）。
- **按键提示音**：NSEvent local monitor 里 handled 的 key 必须 return nil，
  否则 AppKit 播「无效输入」beep（handleKey 已改返回 Bool）。
- **display-link 2.7Hz 魔咒不是多实例独有**：单实例长跑 + 自动熄屏/窗口遮挡同样
  触发（2026-10-04 59 分钟实例尸检）；事件驱动的 AI 路径完全不受影响（tiles/s 照常），
  只有 display 侧停摆。熄屏后进程消失（exit -1 无崩溃报告），worker BrokenPipe 是
  下游症状。
- **场景 v3 构图记录**（SceneShaders.swift，sq-ai-demo/Studio 共用）：mandelbox-lite
  分形水晶（box fold+sphere fold，4 迭代，DE×0.45，1.6 倍局部缩放置 (0,5,-16)，
  包围球 r1.7 壳外只做保守步进绝不当命中面——分形太大/过曝是第一次迭代踩的坑，
  构图速算：fov25° 半帧 12.5°，水晶角半径 ~2.7°≈1/5 半帧刚好）；频谱石柱
  （hash 格子绑 bass/mid/treble 频段，柱高=频段能量，柱距 3.2 只算最近格）；
  voronoi 返回 (F1, F2-F1, cellHash) → 彩虹脉络保配色丰富度；ember 粒子=解析式
  光点（0.004/(d²+ε) 按首命中遮挡），不做真 raymarch 球。
  撞色方案：天空青↔橙互补对整体随 mid/treble 摆（幅度 0.33/0.18）+ beat 色相踢
  0.15 + satPop；太阳/柱子/粒子用不同倍率错位撞色。

## 场景 v4 动态化 + 显示层改版（2026-10-05 固化，docs/scene-v4-plan.md）

- **v4 动态化**：太阳 lissajous 漂移 + vnoise 半径呼吸 + 球面位移形变（az/el fbm2
  + bass 赤道波纹 + beat 涟漪 + 下半球蜡泪 drip，近壳 sunR*2.2 内才算位移，DE×0.8）；
  水晶慢速轨道（±1.4x/±1.2z）+ 双轴进动 + melt domain-warp（DE×0.7）；地板 fbm
  双向滚动+缓旋 + 单层 vnoise 反向细节 + melt warp + beat 弹坑（audio.w>0.001 门控）；
  走廊蛇形中线 corridorX(z,t) + 相机自主漂移（ro.x 0.8·sin(0.13t)、dolly、俯仰微摆）。
  融化统一标量 `melt=clamp(0.3+bass*0.5+mid*0.3,0,1)`；石柱↔地板 smin 融合
  （k=2.5·(0.4+0.6melt)，多项式版 smin 对 1e5 哨兵值安全）。
- **性能实测**（--bench-base，串行 waitUntilCompleted 拆 command buffer；不串行时
  GPU 时间戳含排队等待会虚高 20 倍）：全量 quilt raymarch v4 ≈ 62.7ms@11x6 /
  30.2ms@7x8，约为 v3.1（52.2/25.6ms）的 1.2 倍。**AI 场景全量渲染从来不在
  帧路径上**（只在启动打底 + G 键 peek 半帧率），live 逐视角 384² staging ≈0.6ms/视角，
  远低于 CoreML 25ms/tile，故 60FPS/tiles/s 不受影响；plan 里 "9ms 预算" 是
  sq-demo 简单场景的数字，对 AI 场景不适用。优化要点：sunRadius 别用 fbm
  （每 map 步都跑，vnoise 单倍频程省 ~12ms/帧）。
- **律动转色相**：beat 不再脉冲亮度。interlace 新增 `mainHue` uniform（绕灰轴
  Rodrigues 旋转，只作用于主 quilt），sq-ai-demo `--beat-hue 0.06`（默认）由节拍钟
  60Hz 驱动；`--beat-glow` 默认 0 留作 legacy。场景侧 beat 闪光收敛
  （sky 0.5→0.15、sun 1.6→0.3、crystal fresnel 0.8→0.3），beat 色相踢 0.15→0.45。
  Studio 侧对应 beatHue 滑条（持久化 studio.beatHue）。
- **像素光强上限**：`LenticularUniforms.maxOut = 0.7`，interlace 最终输出
  `min(outCol, maxOut)`（tonemap+overlay 之后）。只影响设备/预览显示路径，
  quilt dump 不受影响（sq-demo md5 基线安全）。
- **明度驱动透明**：太阳/水晶暗部按 Rec.601 明度混入天空
  （sun smoothstep(0.30,0.95) → 扫描线间隙成悬浮光带；crystal smoothstep(0.05,0.38)
  → 暗刻面玻璃化）。地板/石柱不做（本体太暗会消失）。
- **歌词浮层 v2**：底部进度条=曲目进度（position/duration）；行进度接口保留为
  卡拉OK覆盖度（dim 无描边半透明底 + liquid glass 亮部按行宽逐行扫 + stroke-only
  rim 高光；LyricOverlayRenderer 缓存 dim/bright/rim 三套 run + title strip 备份，
  4Hz 只重绘 strip）。**覆盖度同步暂禁用**（LRCLIB 行窗 + 位置外推漂移），调用点
  固定 coverage:1 全亮，接口保留。glass 渐变用 transparency layer + .sourceIn
  （ctx.clip + NSString.draw 组合不生效的坑）。头部双行排版（track 大字玻璃体 +
  artist tracked caps + 渐变 tick），subtitle 按 " — " 拆分。视差默认 0.10。
- **高光保饱和**：太阳条带峰值 (0.35+1.3stripe)×1.8≈3.0 深进 ACES 肩部会洗白，
  压到 (0.35+1.0)×1.15≈1.55；天际辉光 0.5→0.3、ember glow cap 2.5→1.4、
  柱帽 v 1.2→1.0、水晶 fresnel 0.7→0.55。地板抬底色（v 0.035→0.09 起 +
  sky×0.05 环境色）。
- **离线消融/目检新参数**：`--audio b,m,t,bt`（dump/peek-dump/overlay-dump/bench
  注入固定 audio uniform，离线做播/停对照）、`--bench-base N`（GPU 计时）。
- git push 卡/超时：本机 shell 代理环境变量会拦 git，用
  `env -u ALL_PROXY -u all_proxy git -c http.version=HTTP/1.1 push`。
- 验收基线：sq-demo --dump md5 caaf1d42f528a58ecd3eeaede99aa554；
  实机 60FPS / ~60 tiles/s / tile ~1.1Hz（v3 场景下）。
