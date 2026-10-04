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
- `lkg-demo --dump` md5 回归不变。

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
