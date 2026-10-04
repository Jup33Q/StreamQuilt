# Plan: 情感引擎 × laya 提示词策略（下次执行）

> 2026-10-04。前置：docs/flicker-fix-plan.md、docs/lyrics-and-peek-plan.md、
> skills/lkg-metal-quilt/SKILL.md。
> laya-coreml 已部署本机（见下「laya 部署现状」）。

## 已完成的前置（本仓库当前 HEAD + WIP commit）

- **情感表 + Ollama 路径已接线（WIP commit 在 git 里）**：
  `Sources/LKGQuilt/AI/EmotionEngine.swift`（14 情感表：id/zh/stylePrompt/hueBias/
  energy/crystalGain/columnGain/emberGain + TrackThemeEngine）、
  `Sources/LKGQuilt/AI/OllamaClient.swift`（/api/chat, format json, 20s 超时, 容错解析）。
  main.swift 已接：`--emotion-engine/--no-emotion-engine`（默认开，仅 music 源）、
  `--ollama`、`--ollama-model gemma4:e4b-mlx`；引擎产出 → `scene.themeBias`（shader
  theme uniform：(hueBias, crystalGain, columnGain, emberGain)，已透传进
  SceneShaders 的 hueShift/水晶/柱高/粒子）+ setPrompt(currentTheme + 歌词行) +
  beatGlow 能量缩放 + 状态行 🎭。
- **歌词链路**：LyricsService（AppleScript lyrics → LRCLIB 兜底，LRC 同步），
  行切换回调带 2s 节流 + 节拍边界量化。
- **laya 部署现状**（~/Documents/kimi/workspace/laya-coreml/）：
  - venv：`.venv`（uv 建，cpython 3.12；**系统 python3 是 3.9 太老，uv 的
    cpython-3.12 符号链接目录有坑要用 `uv venv`**）
  - 包：`laya-coreml`（PyPI，阿里镜像装的）
  - 模型：`models/multilingual`（1024 token，CPU+GPU，~13ms/决策）、
    `models/multilingual-ane`（**96 token 总上限**，ANE，~6ms/决策）——
    均由 `HF_ENDPOINT=https://hf-mirror.com .venv/bin/hf download` 拉取（HF 直连超时）
  - 冒烟脚本 `smoke_emotion.py`：14 选项情感分类，中英歌词实测通过
    （1024 模型答案更准，ANE 更快；两者 choice 偶有分歧，都合理）
  - API：`agent = laya.load(本地目录)`；`agent.predict(text, {"emotion": {"type":
    "choice", "criteria": [选项...], "instructions": "..."}})` →
    `r["answers"]["emotion"]["choice"]` + `["probabilities"]`；
    另有 `"score"`（ordinal）和 `"noul"`（布尔）题型。96 token 含问题+选项+正文，
    instructions 要短、歌词行截 ~80 字符。
  - 模型加载慢：1024 约 7s、ANE 首次约 26s（CoreML 编译）→ 必须常驻 sidecar 进程，
    不能每次 spawn。

## 剩余任务

### E1 — LayaClient sidecar（Swift ↔ Python 常驻进程）
- 新 `python/laya_emotion_worker.py`：stdin/stdout 行 JSON 协议（{"id":N,"text":...,
  "questions":{...}} → {"id":N,"answers":{...}}），加载哪个模型由启动参数定
  （--model-dir）。stderr 打印日志（stdout 保持协议干净——参考 quilt_diffusion_worker
  的 dup2 踩坑，本协议走行 JSON 无需 dup2，但初始化 print 要打 stderr）。
- Swift 侧 `LayaClient`（仿 DiffusionClient 的 Process+Pipe 骨架，但请求/响应是行
  JSON，允许并发 in-flight 用 id 配对）。
- CLI：`--laya on/off`（默认 on）、`--laya-python ~/Documents/kimi/workspace/laya-coreml/
  .venv/bin/python`、`--laya-models ~/Documents/kimi/workspace/laya-coreml/models`。

### E2 — laya 接入 TrackThemeEngine（替换/增强 Ollama 角色）
- **逐行情感（ANE 96-token，~6ms）**：歌词行切换 → laya choice(14 情感)。
  用 probabilities 做滞后切换（新情感概率 > 旧情感 +0.15 才换，防抖动）。
  行情感 → 调制 prompt 后缀 + 短期 energy。
- **整曲主题（1024 token，~13ms）**：换曲 → laya choice（预设主题表，见 E3）+
  整曲情感 choice。主题表是 choice 不是生成——**laya 不生成文本**。
- Ollama 保留为可选自由文本路线（`--theme-brain laya|ollama|hybrid`，默认 laya；
  hybrid = laya 情感 + ollama 自由主题句）。
- pace/phase（规则，已有 WIP）：行密度 + 重复行判定 chorus → energy 短期 +0.3。

### E3 — 主题/风格多样性扩充
- 在 EmotionEngine.swift 旁加 `Theme` 表（~12 个）：水墨山水/赛博朋克雨夜/浮世绘/
  吉卜力田园/复古航天海报/蒸汽波/像素霓虹/印象派油画/剪纸/低多边形/黑白木刻/
  敦煌壁画——每个带完整 SD prompt 片段 + 推荐 hueBias + element gains。
- 主题表同时供 laya choice 的 criteria 和 Studio 下拉框。

### E4 — 验收
- `swift build` 全过；`lkg-demo --dump` md5 = caaf1d42f528a58ecd3eeaede99aa554。
- 实机：换曲/行情感切换可见（状态行 🎭 变化 + prompt 日志），60FPS/≥50 tiles/s 不回退。
- lay a worker 随 app 退出清理（SIGTERM 双保险，参考 DiffusionClient.stopAll 教训）。

## 激活提示词（新 session 粘贴）

```
激活 lkg-metal-quilt 的情感引擎×laya 子任务（E1–E4）。

先读恢复上下文（本机）：
1. ~/Desktop/lkg-metal-quilt/docs/emotion-prompt-plan.md ← 本 plan（含 laya 部署现状、
   API、96 token 坑、sidecar 协议要求）
2. ~/Desktop/lkg-metal-quilt/Sources/LKGQuilt/AI/EmotionEngine.swift + OllamaClient.swift
   （Ollama 版 WIP 已接线，HEAD 里；本次把 laya 作为新 brain 接入，参考其接线点）
3. ~/.kimi-code/skills/lkg-metal-quilt/SKILL.md（全部踩坑：sidecar 清理、多实例、
   display link、PyPI/HF 镜像）
4. ~/Documents/kimi/workspace/laya-coreml/smoke_emotion.py ← laya 调用范例（已验证）

关键上下文：
- laya 是 typed-decision 模型（choice/score/noul），不生成文本；主题扩充走预设表 choice。
- ANE 模型 96 token 总上限（问题+选项+正文），逐行情感用它（~6ms）；整曲主题用
  1024 token 模型（~13ms）。模型加载 7~26s → 必须常驻 sidecar。
- 逐行情感要滞后切换（新概率 > 旧 +0.15 才换）防抖动；行切换已有 2s 节流+节拍量化。
- 硬性约束：60FPS/≥50 tiles/s 不回退；lkg-demo --dump md5 回归 caaf1d42…；
  起新实例前 ps aux | grep lkg-ai-demo 清残留；git push 用
  env -u ALL_PROXY -u all_proxy git -c http.version=HTTP/1.1 push（网络抖就两种都试）。
```
