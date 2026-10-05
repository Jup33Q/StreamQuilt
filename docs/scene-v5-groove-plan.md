# Plan: 律动穿透 shader 重设计（v5 / S6）

> 2026-10-05。前置：v4 已推送（commit 10cd966）；S5 真实音频+音高已完成实机验证
> （**工作区未提交**：groove 引擎 v2 + AudioDSP/SystemAudioAnalyzer/pitch 通道 + 本 plan，
> 激活后第一步先提交）。本 plan 解决 S5 实机暴露的问题：**律动对 StreamDiffusion
> 生成层影响不大**——节律看得见（显示层），但生成的图案内容本身不随音乐「长」。

## 问题定位（S5 实机结论）

| 观察 | 根因 | 证据 |
|---|---|---|
| 音频调制进了 raymarch 输入，但 AI tile 里几乎看不到 | img2img 是有损通道：strength 0.6 下扩散先验保留构图/几何，吸掉小幅 hue/亮度调制 | 架构分析；v4 起 hue 类响应主要靠显示层 mainHue 才可见 |
| beat 类快变量在平铺上读作噪声而非律动 | tile ~0.6Hz/视角刷新 × beat 周期 ~0.5s → 56 个 tile 随机相位快照（N6 已固化） | N6 频闪治理结论 |
| 真音频的慢信号（乐句能量、段落、音高区）是空间相干的 | 整屏 56 tile ~2s 扫完一轮，同一时刻的 real features 对所有 tile 一致 | S5 实机日志：[audio] sys 行 |

**设计结论：快慢分离。**
- 快变量（beat 脉冲，<1s）→ 显示层 interlace uniform（60Hz 全屏相干），shader 内不再投预算；
- 慢变量（乐句能量/段落/音高区，2–8s）→ 场景**几何与结构**参数（能活着穿过扩散）；
- shader 的音频预算从「色相/亮度微调制」重投到「结构律动」。

## v5 改造点（SceneShaders + 少量 Swift 侧）

1. **慢能量包络 uniform**：Swift 侧（AudioDSP.Output 之外或 main/Studio 接线处）对
   real features 做 2–4s EMA 得 slowEnergy（bass/mid 加权），追加进 params 尾部
   （沿用 audioPitch 的尾部追加法，默认 0 位级中性）。shader 内用它驱动**大幅度**
   结构变化：melt 幅度、柱高动态范围、太阳半径呼吸幅度、走廊蛇形幅度、相机 dolly 行程。
2. **beat 撤资色相/亮度，转投几何**：sky flash / beat 色相踢进一步收敛或移除
   （显示层 mainHue 已负责）；保留并加强几何类 beat 响应（地板弹坑/涟漪、
   kick 同步的相机 dolly step——量化到 beatClock 边界，一拍一步而非连续正弦）。
3. **音高锚定分层**：scene 内 audioPitch 保留（raw 层/G-peek 有效）；AI 主层的
   音高显色改走显示层——`mainHueProvider` 返回值加 `pitchTurns × gain`
   （main.swift / StudioModel 接线，60Hz 相干，无扩散衰减）。
4. **相机律动增益**：v4 的 `ro.x += sin(t*0.5)*(0.4mid+0.25bass)` 提高到主观可见，
   并叠加 kick 触发的 z 向 push（慢起快回，避免晕动）。
5. **真音频归一曲线复核**：自适应峰值归一（0.995 慢放）在真音乐下的 bass 动态
   偏弱（S5 实机 b 值多在 0.01–0.39）；评估 attack/decay 或改 band 求和→峰值
   检测，让 bass 段在真鼓点下打满 0–1。

## 方向 B：Blender 生成 3D 资产（两条子路线）

纯 shader（raymarch SDF）建模的天花板在于「复杂具象结构」——雕塑感主体、
机械/有机细节、可读的造型语言。这些恰是几何级内容，**律动调制的穿透性最好**。
2026-10-05 无头 spike（Blender 5.2.2 Steam）实测两条桥都通，按场景气质选型：

### B1：mesh 光栅路（细节/材质优先）

- Blender → 高模雕刻/生成 → **高模→低模法线烘焙**（skills/blender-normal-bake
  无头管线，本机已验证：Cycles selected-to-active + cage 自动扫描 + 缺陷检测
  JSON 报告 + 4 视角目检）→ 低模 + 法线图 → 新 mesh renderer（QuiltMath 离轴
  投影 + 前向 pass）进同一 staging → img2img 管线不动。
- **spike 结果**：溶球高模(2547 面)→低模(886 面) 烘焙 status:"ok"、coverage 1.0、
  法线方向正确（mean B 0.996）、4 视角目检正常。
- **坑：MDLAsset 本机不认 .glb**（"unknown extension"，meshes=0）——
  Model I/O 路径导出用 **OBJ 或 USDZ**，别用 glb。

### B2：mesh → SDF 体素网格路（气质统一优先，推荐先试）

- Blender 网格 → 无头脚本体素化成 SDF 网格（mathutils.bvhtree 最近面距离 +
  射线奇偶判内外，float16 3D 纹理 + JSON 元数据）→ raymarch shader 里作为
  一个 DE 采样——**资产直接融入现有 SDF 场景**：smin 融合、domain warp、
  melt 全套变形照常生效，无需新 renderer。
- **spike 结果**：96³ fp16（1.77MB）体素化仅 3.8s，inside 10.2% / 近表面带
  6.0% 分布正常；128³–256³ 直接可用（256³ fp16 ≈ 33MB）。
- 细节上限是网格分辨率，没有法线图概念；要表面细节叠程序化噪声或走 B1。

### 溶球（metaball）结论

- **静态形态可导出**：convert(target='MESH') 后是正常流形网格（spike：0 非流形
  边），烘焙/体素化/glb/obj 全通。
- **活体融合动画出不了 Blender**：隐式曲面场不进任何交换格式。要「球体融合/
  分离」的动态，正解是在 SDF 场景里用 smin 现算（v4 已有全套基础设施），
  Blender 只负责提供静态 hero 形状（网格或 SDF 网格）。
- 混合路线照旧有效：raymarch 背景（v4 氛围）+ Blender 主体资产。

## SDF 溶球液体感增强（v5 设计细节）

smin 球场本身只是「软球」，液体感来自表面张力、粘性流动与光学三层细节，
全部可在现有 raymarch 框架内做（DE 变形沿用 v4 的 Lipschitz 折扣纪律）：

- **融合颈缩（surface tension）**：smin 的 k 不再全局固定——k 随 melt/slowEnergy
  连续变化（能量高 → k 大 → 更稀更融合；安静段 → k 小 → 球体分明），并叠加
  距离偏置让分离瞬间拉出细长液颈再断开（k_eff = k · f(间距)）。
- **表面颤动（capillary wobble）**：低频 fbm domain warp（2–3 倍频程，幅度随
  beat/能量调制）只作用于球壳附近（v4 已有「近壳才算位移」的预算模式），
  DE×0.7–0.8 折扣；安静段保留微小自主颤动不死板。
- **粘性拉伸（viscous drag）**：每个溶球团有速度向量，SDF 沿速度反方向椭球
  拉伸（stretch ∝ |v|），运动越快越拉丝；球心沿流场慢速平流（v4 太阳
  lissajous 的流场版），急转时拖尾。
- **滴落/泪垂（drip）**：v4 太阳下半球蜡泪推广为通用算子——低于某 y 阈值
  施加向下单方向 warp + 周期性凝出小滴（小 SDF 球沿重力加速脱落、撞地板
  溅开成薄饼 smin 回地面）。
- **beat 涟漪**：beat 脉冲在球面激发同心波纹（v4 太阳涟漪同款，幅度跟随真实
  beat）；kick 重拍可让整团液体「跳」一下（瞬时 y 向 squash & stretch，
  几何级，穿透扩散）。
- **液体光学**：高光 spec 拉高 + fresnel 边缘亮 + 薄处透光（按 SDF 梯度/
  局部厚度近似的假 SSS）+ 环境色反射；色相仍由显示层 mainHue 统一负责。
- **与音频的映射**（快慢分离不变）：slowEnergy → 融合度 k、流场速度、滴落
  频率；beat → 涟漪/squash（几何）；pitch → 显示层色相，不进 SDF。

## 约束（验收红线，逐条继承）

- **audio=0 / pitch=0 / slowEnergy=0 位级不变**：所有新响应默认中性；
  `sq-ai-demo --peek-dump` 复跑与 S5 终版逐位一致。
- **sq-demo md5 基线 caaf1d42f528a58ecd3eeaede99aa554 不变**（sq-demo 独立场景，
  本就不受影响，复跑确认）。
- epoch=floor(sceneTime)/beatClock 量化、tile 三段交叉淡入、N1 明度归一链路不动。
- 快变量不进 shader 亮度/色相（防 N 系频闪回归）；shader 内 beat 只做几何。
- 性能：`--bench-base` 对比 v4 基线（30.2ms@7x8 / 62.7ms@11x6）涨幅 <10%；
  live 60 FPS 与 tiles/s 不回退（AI 场景全量渲染不在帧路径上，逐视角 staging
  ~0.6ms 预算内）。
- 实机前 `ps aux | grep -E "sq-|streamquilt"` 清残留；push 用
  `env -u ALL_PROXY -u all_proxy git -c http.version=HTTP/1.1 push`。

## 验收

- `swift build -c release` 过；peek-dump 位级回归；sq-demo md5 不变。
- 离线消融：`--peek-dump --audio 0.8,0.4,0.2,1` vs `--audio 0,0,0,0` 的
  -quilt.png 目检——几何差异清晰可见（不再是只有色相差异）。
- 实机（.app + Music）：system 音源下乐句级能量起伏在生成图案里可读
  （结构/构图级变化）；beat 在显示层可读；长看 5min 无频闪回归。
- S5 踩坑固化进 skills/streamquilt/SKILL.md（见下「S5 已固化经验」）。

## S5 已固化经验（激活时先写入 SKILL.md 再动手）

- **SCStreamOutput 的协议 witness 是 `stream(_:didOutputSampleBuffer:of:)`，
  不是 `streamOutput(...)`**；协议方法全 @optional，写错名字编译不报错、
  回调永远不来（S5 实机全零查了四轮）。
- CMSampleBuffer → AudioBufferList 要两段式：先 `bufferListSizeNeededOut` 问尺寸，
  用可复用 storage 第二次真正取（单 AudioBufferList 栈变量装不下非交错多声道，
  会静默 noErr 失败路径返回）。
- ScreenCaptureKit 应用音频捕获本机已验证：2x2/1fps 视频 + 48k mono 音频，
  TCC 权限对 .app 一次授权后 CGPreflight 直过；`[audio] first buffer` 一行
  诊断（buffer 数/声道/帧率/rms）值得保留。
- 自相关 pitch（80–1200Hz，vDSP_dotpr 指针偏移）对流行歌主旋律实测可锁
  （conf 0.4–0.85）；置信度门控 0.35 + α0.25 平滑 + 低置信保持上次值，
  未见色相跳变。

## 激活提示词（新 session 粘贴）

```
激活 StreamQuilt 律动穿透 shader 重设计（v5/S6）。

先读恢复上下文（本机）：
1. ~/Desktop/StreamQuilt/docs/scene-v5-groove-plan.md ← 本 plan（快慢分离原则 +
   5 个改造点 + 约束红线 + 验收）
2. ~/Desktop/StreamQuilt/Sources/StreamQuilt/AI/SceneShaders.swift ← 场景 shader 现状
   （v4 动态化 + S5 audioPitch 尾部字段；audio=0 必须位级中性）
3. ~/Desktop/StreamQuilt/Sources/StreamQuilt/AI/AudioDSP.swift ← 真音频特征源
   （Output{bass,mid,treble,beat,pitchHz,pitchTurns,pitchConfidence}）
4. ~/.kimi-code/skills/streamquilt/SKILL.md（N1–N6 频闪治理、v4 构图与性能基线）

关键上下文：
- S5（真实音频+音高）已完成实机验证但未提交：第一步先把 S5 工作区提交
  （groove v2 + AudioDSP/SystemAudioAnalyzer/pitch 通道 + 本 plan），
  并把 plan 里「S5 已固化经验」4 条写进 SKILL.md。
- 核心认知：img2img 是有损通道，hue/亮度快调制穿不过扩散；快变量走显示层
  （interlace mainHue 60Hz 相干），慢变量（2-8s 能量/音高区）走场景几何。
- 资产路线：纯 shader 建模不够用就走方向 B——两条子路线 2026-10-05 spike 已验证：
  B1 高模→低模法线烘焙（blender-normal-bake skill，溶球实测 status:ok）+ mesh
  renderer（注意 MDLAsset 不认 .glb，导出用 OBJ/USDZ）；B2 mesh→SDF 体素网格
  （bvhtree 体素化 96³/3.8s，脚本已入库 scripts/sdf_voxelize.py +
  scripts/metaball_spike.py）直接进 raymarch 当一个 DE，smin/melt/warp 全套
  兼容，推荐先试。
- 溶球：静态形态 convert 后可导出（0 非流形），活体融合动画出不了 Blender——
  动态融合在 SDF 场景里 smin 现算；液体感增强设计细节（颈缩/颤动/粘性拉伸/
  滴落/涟漪/光学 + 音频映射）见 plan「SDF 溶球液体感增强」节，逐条落实。
- 约束：audio=0/pitch=0/新 uniform=0 位级中性；peek-dump 复跑逐位一致；
  sq-demo md5 caaf1d42f528a58ecd3eeaede99aa554 不变；epoch 量化不动。
- 实机验收用 .build/StreamQuilt-AI-Demo.app（scripts/build_app.sh），
  --audio-source system；先 ps aux | grep -E "sq-|streamquilt" 清残留。
- push 用 env -u ALL_PROXY -u all_proxy git -c http.version=HTTP/1.1 push。
```

## S6 执行记录（2026-10-05 完成）

- **架构变更（未在原文）**：v4 场景源码一字节不动（sceneMSL），v5 整套另存
  sceneMSL5 独立 MTLLibrary，encode 时 slowEnergy>0 || kickEnv>0 选 v5 PSO。
  原因：Metal fast-math 的 FMA 融合/重排使「数学上恒等的表达式编辑」也会
  翻转像素（实测：拆局部变量、加 if 门控、系数 runtime 化全部漂移）；
  函数返回值边界传参安全，内联表达式形态改动一律不安全。
- 调参：地形 slow 系数 0.7→0.35（melt=1 时地形淹没中景）；溶球锚点
  (-1.8,4.6,-5.0)、半径 0.38+0.20h（原 -2.6/4.2/-5.0 在相机大摆动下出画）；
  相机 groove 1.1/0.6→0.85/0.5。
- 验收：peek-dump 位级 = S5（f23068ef/4f39d076）；sq-demo md5 不变；
  消融 on/off 几何差异显著（溶球+滴落+地形浪涌）；bench v4 21.3ms /
  v5 27.1ms @7x8；实机 system 音源 60FPS、bass 峰值 0.5+、pitch 锁定、
  blob/滴落离线矩阵（t=1.2/15/40）可见。
- 观察：Music 实机两次自动暂停（36s/143s 处），原因未查明，非 app 行为。

## S6.1 追加（2026-10-05，用户实机反馈迭代）

- accumEnergy（第三个尾部 uniform，只增不减）驱动**地形不可逆累计形变**
  （沉积 warp，warpA=min(accum*0.06,1.6) 随 accum 平移）+ **配色随播放时间
  演化**（hueShift += accum*0.01 全局锚点 + 逐元素异速漂移）。
- 律动淡化 + bass 全局削弱 ~50%（地形瞬时响应、melt、太阳、相机、溶球、
  地板着色；slowEnergy bass 权重 0.75→0.55）。
- 去泛白：场景饱和度 0.85–1.0、辉光/地平线/fog 收敛；默认 prompt
  pastel → vivid highly saturated。
- 回归：peek-dump 默认仍 f23068ef（v4 冻结不受影响）；sq-demo md5 不变。

## S7 深度参考旁支（2026-10-05 追加，超出原 plan 范围）

- raymarch tRay 经 MRT 输出逐视角深度（v4 不写入=全远=旧行为），worker 按
  深度在 **latent 输出侧** 合成 `m*denoised + (1-m)*clean`。
- 教训：1-step turbo 下「深度缩放注入噪声」会让整图丢风格变浆糊（npred 假定
  统一 t）；输出侧合成不动采样数学，一次通过。
- 实测：60FPS / 44 tiles/s 无回退，dump 时长不变。
