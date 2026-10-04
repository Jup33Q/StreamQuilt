---
name: lkg-metal-quilt
description: >
  用 Swift + Metal 为 Looking Glass 光场显示器（LKG Go 等）做实时 quilt 渲染的本地库与 demo。
  当用户要「Metal 实时渲染到 LKG / Looking Glass」「实时 quilt」「光场显示器渲染管线」
  「柱镜 interlace / lenticular 交织」「从 Bridge 取校准参数」「lkg-metal-quilt 项目」
  「给 LKG Go 写原生 app」时使用。仓库：https://github.com/Jup33Q/lkg-metal-quilt
  本地路径：~/Desktop/lkg-metal-quilt
---

# lkg-metal-quilt — Metal 实时 quilt 渲染

Swift + Metal 的 Looking Glass 实时渲染管线（真机验证：LKG Go / LKG-E10707 + M5 Max，
4092×4092 全分辨率 66 视角，稳定 60 FPS）。纯 SwiftPM 包，无需 Xcode（shader 运行时编译）。

- 仓库：https://github.com/Jup33Q/lkg-metal-quilt
- 本地：`~/Desktop/lkg-metal-quilt`（`swift run -c release lkg-demo` 即跑）

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
cd ~/Desktop/lkg-metal-quilt
swift run -c release lkg-demo                  # LKG 全屏 + 主屏预览窗
swift run -c release lkg-demo -- --no-preview  # 只上设备
```

按键（先点预览窗聚焦）：q 退出 · s/S 存 quilt/交织 PNG · f 视差反向（画面内翻时用）·
`-=` 视差幅度 · `[]` 相机距离 · `90` FOV · 1/2 全/半分辨率 · p 暂停 ·
b 绕过 interlace 显示裸 quilt · c 校准测试图（每视角纯色：对齐正确时整屏单色、
转头颜色连续变化；有彩虹纹=校准错位）。

离线出图（QuiltPlayer 兼容命名）：`lkg-demo -- --dump out_qs11x6a0.56.png --time 1.2`，
交织图 `--dump-lentic lentic.png`。

### 作为库集成

```swift
.package(url: "https://github.com/Jup33Q/lkg-metal-quilt.git", from: "0.1.0")
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
`Sources/lkg-demo/BlockCityScene.swift`。

## 性能参考（M5 Max）

| 阶段 | GPU 耗时 |
|---|---|
| 场景 raymarch（66 视角 4092²） | ~9 ms |
| interlace（1440×2560） | 亚毫秒级 |
| 总帧率 | 60 FPS（vsync 锁定） |

性能坑：interlace 会从 64MB fp16 quilt 纹理散射采样，别把 quilt 拷来拷去；
预览窗限 30Hz（否则主屏 120Hz 的 blit 会抢 GPU）。GPU 计时注意
`gpuStartTime/EndTime` 包含 vsync 等待，测量要拆 command buffer。

## AI quilt 管线（lkg-ai-demo，2026-10-04 实测固化）

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
- `Sources/lkg-demo/` — 方块城市 demo 场景
- `Sources/lkg-ai-demo/` — AI 风格化 demo（DiffusionClient worker 池 + AIQuiltCoordinator
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
  拖到 ~2.7Hz。起新实例前 `ps aux | grep lkg-ai-demo` 清干净；TaskStop 只杀 bash 壳，
  Swift 进程要用 exec 直挂或显式 kill。
