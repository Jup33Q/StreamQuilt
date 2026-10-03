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

## 文件地图

- `Sources/LKGQuilt/QuiltSpec.swift` — quilt 网格规格（.lkgGo / .lkgPortrait / 自定义）
- `Sources/LKGQuilt/Calibration.swift` — 校准模型 + Bridge REST 拉取 + 内嵌回退值
- `Sources/LKGQuilt/QuiltRenderer.swift` — HDR quilt 目标 + tonemap/interlace/测试图 pass + PNG 导出
- `Sources/LKGQuilt/LKGApp.swift` — AppKit 外壳（LKG 全屏窗 + 预览窗 + 按键 + 帧循环）
- `Sources/LKGQuilt/LKGShaderCommon.swift` — 场景 shader 公共 prelude（tile 数学）
- `Sources/LKGQuilt/LKGFixedShaders.swift` — interlace/tonemap shader（运行时编译）
- `Sources/LKGQuilt/QuiltMath.swift` — mesh 内容的离轴相机矩阵
- `Sources/lkg-demo/` — 方块城市 demo 场景
