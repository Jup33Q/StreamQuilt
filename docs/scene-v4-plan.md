# Plan: 场景 v4 —— 动态化改造（太阳/水晶/地板/走廊中线）

> 2026-10-05。对象：Sources/StreamQuilt/AI/SceneShaders.swift（StreamQuilt app 与
> sq-ai-demo 共用）。前置：skills/streamquilt/SKILL.md（场景 v3 构图记录、
> 性能预算、N1–N6 频闪治理）、docs/studio-ui-and-lyric-overlay-plan.md。

## 问题定位（代码映射）

| 用户观察 | 代码位置 | 病根 |
|---|---|---|
| 噪波球占位大、太固定 | `map()` 的太阳 `dSun`（圆心写死 (0,6,-24)，半径只在 bass/beat 上微脉冲 2.1×(1+0.22b+0.10w)）；水晶 `crystalCenter` 锚死 (2.2,4.8,-8)，只有 0.3 幅度 y 浮沉 | 位置/尺寸无慢速演化，纯脉冲 |
| 地板噪波死 | `terrainH`: `fbm(xz*0.16 + (0, t*(0.25+mid*0.6)))` | 只沿 z 单方向慢速滚动，无旋转/无第二层细节 |
| 格点死 | terrain 着色 `fract(p.xz/1.5)` 网格线 | 网格空间位置完全静止，只有颜色随时间变 |
| 走廊中线不动 | `h *= smoothstep(0,3,abs(xz.x))` | 走廊钉死 x=0；相机只有 `sin(t*0.5)*0.5*mid` 的音频摆动，安静时完全静止 |

## v4 设计

### S4-1 太阳（synthwave sun）
- 慢速漂移：圆心加 lissajous 漂移 `x = 2.6*sin(t*0.11)`, `y = 6.0 + 0.8*sin(t*0.07)`，
  半径基础值 2.1 → 1.7 + 0.5*fbm(t*0.05)（慢噪声呼吸，不再只靠节拍）。
- **形状变化（球面位移，不再是完美球体）**：半径沿方向角域调制 —
  取命中方向 `d3 = normalize(p - C)`，用球面坐标 `(azimuth, elevation)` 采
  vnoise/fbm 做位移：
  ```
  float az = atan2(d3.z, d3.x), el = asin(d3.y);
  float disp = fbm(float2(az * 2.0, el * 2.0) + float2(t * 0.10, t * 0.07))  // 慢速流动
             + audio.x * 0.5 * sin(az * 6.0 + t * 2.0)                        // bass 赤道波纹
             + audio.w * 0.3 * sin(el * 12.0 - t * 6.0);                      // beat 高频涟漪
  float sunR_eff = sunR * (1.0 + (disp - 0.5) * 0.45);                        // ±20% 形变
  float dSun = (length(p - C) - sunR_eff) * 0.8;                              // 0.8 保守步进
  ```
  位移幅度 ≤ 0.45×sunR 且距离乘 0.8 安全系数（位移 DE 非严格保守，防穿透步进）。
  条纹沿用世界空间 p.y，位移后自然扭曲出「熔岩球」质感。
- **融化滴落（drips）**：下半球叠加下垂位移，蜡泪感 —
  ```
  // el < 0 的下半球：az 相位噪声 × 下垂度，底部拉出不规则「蜡泪」尖
  float dripMask = smoothstep(0.1, -0.5, d3.y);
  float drip = fbm(float2(az * 3.0 + 7.0, t * 0.25)) * dripMask;
  sunR_eff += drip * (0.5 + audio.x * 0.8) * 0.5;   // bass 越大滴得越长
  ```
  （位移幅度预算合计仍 ≤0.45×sunR；先写进同一 disp 累加器再统一 clamp。）
- 性能：map() 逐步都过太阳分支，位移限 1 次 2-octave fbm + 2 个 sin；
  只在 `length(p-C) < sunR*2.2` 的近壳区域才计算位移，远处用纯球距保守步进。
- 扫描线速度与 mid 挂钩：`fract(p.y*(1.4+mid*0.5) - t*(0.25+mid*0.6))`。

### S4-2 水晶
- 锚点改慢速轨道：`crystalCenter` 加 `x = 2.2 + 1.4*sin(t*0.09)`，
  `z = -8 + 1.2*cos(t*0.13)`（注意不越过焦点面太远，保持 3D 可读）；
  翻滚轴从固定 xz 旋转改为随时间进动的双轴旋转。
- **融化感（domain warp）**：crystalDE 采样点加低频域扭曲
  `p += 0.08 * (fbm(p.xy*1.5 + t*0.2) - 0.5)`（分形 DE 对扭曲敏感，
  幅度压小 + 返回距离 ×0.7 保守系数）；beat 时 fold scale 呼吸保留，
  叠加 warp 幅度 `*(1+beat*0.6)` —— 节拍上「软化」一下再弹回。

### S4-2b SDF 融化工具箱（共享）
- **smin 融合**（metaball 熔化）：
  `smin(a,b,k) = -log(exp(-k*a)+exp(-k*b))/k` 或多项式版。
  - 石柱↔地板：columnField 的柱距与 terrain 距离做 `smin(d_col, d_terrain, k=2.5)`
    → 柱子像从熔融地面里长出来，根部不再有硬交界。
  - smin 保持 DE 安全（两场均保守时结果仍保守），无需降步进。
- **domain warp**：`d += (fbm(p.xz*freq + t*speed)-0.5) * amp`；破坏 Lipschitz 界，
  使用该扭曲的对象步进 ×0.7。amp 随 mid 缓慢调制（安静=硬表面，激烈=熔融）。
- **滴落 drip**：下半部 mask × 相位噪声 × 下垂量（见 S4-1）。
- 全部融化的「度」收敛为一个标量 `melt = clamp(0.3 + audio.x*0.5 + audio.y*0.3, 0, 1)`，
  各处统一引用，安静段落回到硬表面（避免一直糊）。

### S4-3 地板（terrain）
- fbm 域动画升级：双向滚动 + 缓慢旋转 —
  `p2 = rot(t*0.03) * xz`，`fbm(p2*0.16 + float2(t*0.18, t*(0.25+mid*0.6)))`，
  再叠一层高频细节 `fbm(xz*0.6 - t*0.3)*0.15`（反向滚动产生干涉感）。
- 网格流动：经典 synthwave 地板滚动 —— 网格坐标向相机方向平流
  `fract((p.xz + float2(0, t*(2.0+audio.x*3.0))) / 1.5)`，x 方向加
  `sin(p.z*0.15+t*0.4)*0.3` 摆动；格点亮闪：per-cell hash 脉冲沿格线传播
  （`hash21(cell)` 选相位的行波）。
- **地板融化**：地形高度叠 domain warp（`melt` 标量驱动），石柱根部与地形
  smin 融合（见 S4-2b）；beat 高峰时地板局部「下陷回弹」——
  ring 冲击波位置的地形高度 `-= ring * 0.4`（波纹压出弹坑再弹回）。
- 注意性能：terrainH 在 map() 里每步都调，新增开销必须 <1ms（sin/rot 常量预计算）。

### S4-4 走廊中线 + 相机
- 走廊蜿蜒：中心线 `x0 = sin(p.z*0.22 + t*0.15) * 1.6 + sin(p.z*0.07 - t*0.06) * 2.2`，
  走廊掩码改 `smoothstep(0,3,abs(p.x - x0))`（蛇形峡谷，随 z 和时间漂移）。
- 相机自主运动：即使音频为零也在动 —— `ro.x += sin(t*0.13)*0.8`，
  `ro.z` 缓慢推进 `-t*0.4 mod 周期`（或往返 dolly），俯仰 `pitch` 微摆。

### S4-5 约束（频闪治理 N 系教训适用）
- 所有运动必须时间连续（禁 hash 跳变）；epoch 量化（floor(sceneTime)）不变。
- 构图护栏：水晶角半径 ≤ 1/3 半帧；太阳漂移后不得出画（fov 25° 半帧 12.5°）。
- 性能预算：场景 raymarch ≤ ~9ms（66 视角 4092²），新增指令控制在个位数 sin/fbm 调用。

## 验收

- `swift build -c release` 过；`sq-demo --dump` md5 = caaf1d42f528a58ecd3eeaede99aa554
  不变（sq-demo 用 BlockCityScene，不受影响，但必须复跑确认没误伤公共代码）。
- 离线目检：`sq-ai-demo --overlay-dump /tmp/v4.png --time 1.2` 对比 `--time 3.0`，
  太阳/水晶/走廊中线位置应有明显差异，太阳轮廓有形变+滴落（非正圆），
  石柱根部与地面无硬交界（smin 融合），地板网格有流动感。
- 消融对照：`--time` 固定、bass 输入有无（播/停音乐）各 dump 一张，
  确认 melt=低 时表面回到硬边（不能一直糊）。
- 实机：60 FPS / ≥50 tiles/s 不回退；安静段落（暂停音乐）画面仍在缓慢运动；
  AI tile 无新增频闪（连续运动不产生跳变）。

## 实施结果（2026-10-05 验收记录）

- build ✓；sq-demo md5 基线多次复跑不变 ✓（BlockCityScene 独立，interlace
  改动不进 quilt dump 路径）。
- 离线目检（--peek-dump 出 quilt）：t=1.2 vs t=3.0/8.0 太阳/水晶/走廊/相机位置
  均漂移 ✓；热音频下太阳形变+蜡泪滴落明显，安静（melt=0.3）回硬边 ✓；
  石柱根部 smin 融合无硬交界 ✓；网格平流+摆动+行波 ✓。
- 性能：新增 `--bench-base N`（串行 waitUntilCompleted，否则 GPU 时间戳含排队
  虚高 ~20 倍）。全量 quilt raymarch v4 = 62.7ms@11x6 / 30.2ms@7x8，v3.1 为
  52.2/25.6（1.2 倍）。**该 pass 不在帧路径**（启动打底 + G peek 半帧率专用），
  逐视角 staging ≈0.6ms 远低于 CoreML 25ms，60FPS/tiles/s 不受影响。关键优化：
  sunRadius 的 fbm→vnoise（每 map 步白跑 3 倍频程，省 ~12ms/帧）；terrain 细节
  层 fbm2→vnoise；beat 弹坑 audio.w>0.001 门控。
- 用户迭代一并并入：水晶 world scale 1.2→0.85（角半径 ~3°）；律动从光强转色相
  （interlace mainHue uniform + 场景 beat 闪光收敛）；像素光强上限 maxOut=0.7；
  太阳/水晶暗部明度驱动透明；太阳/天际辉光/ember/柱帽亮度压 ACES 肩下保饱和；
  地板抬底色 + 天空环境色 5%；歌词浮层：底栏=曲目进度、行进度=卡拉OK覆盖度
  （liquid glass 渐变 + 无描边 dim + rim 高光）、头部双行排版、视差默认 0.10。
- 新 CLI：`--audio b,m,t,bt`（离线消融）、`--bench-base N`、`--beat-hue`、
  `--overlay-shift`。

## 激活提示词（新 session 粘贴）

```
激活 StreamQuilt 的场景 v4 动态化改造（S4）。

先读恢复上下文（本机）：
1. ~/Desktop/StreamQuilt/docs/scene-v4-plan.md ← 本 plan（问题定位表 + 四节设计 + 约束）
2. ~/Desktop/StreamQuilt/Sources/StreamQuilt/AI/SceneShaders.swift ← 改造对象
   （map() 的 dSun/crystalCenter、terrainH、terrain 着色的 fract 网格、
   smoothstep 走廊掩码、shadeScene 的 ro 相机摆动；融化工具箱是新加的
   smin/domain-warp/drip 辅助函数）
3. ~/.kimi-code/skills/streamquilt/SKILL.md（场景 v3 构图速算、N1–N6 频闪治理、
   双 renderer 黑屏、多实例清理、性能预算 9ms/60FPS/≥50 tiles/s）

关键上下文：
- 项目已从 lkg-metal-quilt 改名 StreamQuilt：lkg-demo→sq-demo、lkg-ai-demo→sq-ai-demo、
  库 import StreamQuilt；仓库 github.com/Jup33Q/StreamQuilt。
- 场景 shader 是 StreamQuilt app 和 sq-ai-demo 共用的 SceneShaders.swift；
  sq-demo 用独立的 BlockCityScene，md5 回归基线 caaf1d42f528a58ecd3eeaede99aa554
  必须不变。
- 频闪约束：场景运动必须时间连续（epoch=floor(sceneTime) 量化不变）；
  AI tile 明度归一/交叉淡入链路不许动。
- 离线目检用 sq-ai-demo --overlay-dump（--time 可换时刻对比，--overlay-text 自定义）。
- 实机验收前 ps aux | grep -E "sq-|streamquilt" 清残留；
  push 用 env -u ALL_PROXY -u all_proxy git -c http.version=HTTP/1.1 push。
```
