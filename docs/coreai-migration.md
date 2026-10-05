# CoreAI / CoreML Swift 迁移可行性备忘录（M3 + M4 结论）

> 2026-10-04，机器：Apple M5 Max / macOS 27 / Swift 6.4（CLT）/ coreai-torch 0.4.3 / coremltools 8.3（venv）· 9.0（conda）

## TL;DR

- **CoreML-in-Swift：可行，已跑通端到端**（`scripts/coreml_spike.swift`）。单视角 img2img 全链路
  （TAESD enc → UNet → euler 单步 → TAESD dec）纯 Swift 完成，输出与 Python 逐数值一致。
  单上下文 21 img/s（UNet 37ms 主导），低于 Python 路径（~45 img/s/worker @384）——
  瓶颈在每次预测的 `MLDictionaryFeatureProvider`/`MLMultiArray` 开销，可用
  `MLPredictionOptions`、异步 prediction、批处理或 MLTensor 优化，工程上可追平。
- **CoreAI（coreai-torch → .aimodel → CoreAIRuntime）：可行，链路已验证**。torch 模型转出
  `.aimodel`（metadata.json + MLIR 字节码 main.mlirb + hash），Python `coreai.runtime.AIModel.load`
  可加载推理；Swift 侧 macOS 27 SDK 自带 `CoreAI.framework`（re-export CoreAIDelegates）+
  `CoreAIRuntime`，`AIModel(contentsOf:) async` → `loadFunction(named:)` →
  `InferenceFunction.run(inputs:)` 全部可用且实测通过（见下文 smoke test）。
  **亮点**：`NDArray(unsafeBuffer: MTLBuffer, ...)` 支持 Metal buffer 零拷贝——
  与 StreamQuilt 的 Metal 管线天然契合，理论上可做到 raymarch → UNet → quilt 全程不下 GPU。
- **迁移工作量评估**：把 SDXS img2img 迁到 CoreAI 需要重转 UNet/TAESD（coreai-torch 支持
  torch.export + decomp 表；SD 的 GroupNorm/SiLU/attention 需要确认 decomp 覆盖度），
  文本编码器同理（或继续用 Python 预计算 embedding 的过渡方案）。估计 1–2 天工程量的
  spike 级别验证，性能预期与 CoreML 同档（同一套编译/运行时底座）。

## 验证记录

### coreai-torch 转换 + 加载（Python）
```
scripts/coreai_smoke_test.py: TinyConv → tinyconv.aimodel → AIModel.load ✓
产物：metadata.json / main.mlirb / main.hash（MLIR 字节码资产）
```

### Swift 加载（macOS 27 SDK 自带框架，CLT 即可）
```swift
import CoreAI   // 不要 import CoreAIRuntime（implementation detail）
let model = try await AIModel(contentsOf: url)            // .aimodel bundle
let fn = try model.loadFunction(named: "forward")         // -> InferenceFunction
let out = try await fn.run(inputs: ["x": ndarray])        // async
// NDArray(unsafeBuffer: MTLBuffer, scalarType: .float16, shape: [...]) 零拷贝
```
实测：`/tmp/coreai-swift` smoke test 通过（load + function descriptor + io names）。

### Swift CoreML img2img（M3 spike）
```
scripts/coreml_spike.swift → 47.7ms/img（vaeEnc 5.8 / unet 37.0 / vaeDec 4.9），
输出 PNG 与 Python 管线像素级一致。
```

## 踩坑记录（迁移必读）

1. **Swift 加载 .mlpackage 必须先编译**：`MLModel.compileModel(at:)` → `.mlmodelc`。
   Python coremltools 加载时自动编译，Swift 不会。（另：`MLModel.compileModel` 产出的
   .mlmodelc 缺 Manifest.json，coremltools Python 反向加载不了——单向使用。）
2. **CoreML prediction 返回的 MLMultiArray 是池化复用的**：读结果必须立刻拷贝，
   否则下一次 predict 后数据被覆盖（我们因此踩出"蓝色噪声汤"）。
3. **ANE vs GPU 数值**：Python coremltools 侧 `.all`（ANE）与 `.cpuAndGPU` 输出逐像素一致
   （A/B 验证过完整 img2img）；但 Swift 侧经 `MLModel.compileModel` 编译的 .mlmodelc
   走 ANE 时 TAESD encoder 输出有显著差异（latent sum 1034 vs 478）——Swift  spike 里
   VAE 保持 `.cpuAndGPU`，仅 UNet 可放 ANE。Python worker 全 ANE 无保真问题。
4. **性能对比**：Python 路径（coremltools C++ 绑定 + 预热缓冲复用）单 worker 384²
   约 45 img/s；Swift spike 21 img/s。差距在每次调用重建 feature provider/数组，
   优化方向：预分配 MLMultiArray 复用、`prediction(from:options:)` + 
   `MLPredictionOptions().usesCPUOnly=false`、或 async prediction 流水线化。
5. macOS 27 升级把 streamdiffusion-mac venv 里的老 scipy wheel 干废了
   （`__thread_bss zero-fill`），用镜像升级修复：
   `.venv/bin/python -m pip install -U scipy -i https://mirrors.aliyun.com/pypi/simple/`。
   （注意：venv 没有 pip 可执行文件，必须 `python -m pip`；PyPI 直连超时，用镜像。）
6. huggingface.co 直连超时：全程 `HF_HUB_OFFLINE=1` + 本地 snapshot 路径加载
   （`scripts/convert_unet_coreml.py` 支持 `--snapshot`）。

## 结论

两条迁移路线都通。短期继续用 Python worker（吞吐高、生态全）；中期 CoreML-in-Swift
可去掉 Python 依赖（ embedding 预计算 + 三个 mlpackage 即可）；长期 CoreAI 路线值得跟
（MLIR 资产 + Metal 零拷贝 NDArray，是 Apple 官方的下一代推理栈，且本机 SDK 已就绪）。
