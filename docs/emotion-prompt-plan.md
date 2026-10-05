# Plan: 情感引擎 × laya 提示词策略（下次执行）

> 2026-10-04。前置：docs/flicker-fix-plan.md、docs/lyrics-and-peek-plan.md、
> skills/StreamQuilt/SKILL.md。
> laya-coreml 已部署本机（见下「laya 部署现状」）。

## 已完成的前置（本仓库当前 HEAD + WIP commit）

- **情感表 + Ollama 路径已接线（WIP commit 在 git 里）**：
  `Sources/StreamQuilt/AI/EmotionEngine.swift`（14 情感表：id/zh/stylePrompt/hueBias/
  energy/crystalGain/columnGain/emberGain + TrackThemeEngine）、
  `Sources/StreamQuilt/AI/OllamaClient.swift`（/api/chat, format json, 20s 超时, 容错解析）。
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

### E4 — 验收
- `swift build` 全过；`sq-demo --dump` md5 = caaf1d42f528a58ecd3eeaede99aa554。
- 实机：换曲/行情感切换可见（状态行 🎭 变化 + prompt 日志），60FPS/≥50 tiles/s 不回退。
- lay a worker 随 app 退出清理（SIGTERM 双保险，参考 DiffusionClient.stopAll 教训）。

## 实施与验收记录（2026-10-04 完成 E1–E3）

- **E1**：`python/laya_emotion_worker.py`（行 JSON 协议；启动时 dup fd1 后 dup2(2,1)，
  协议帧走私有 fd os.write，laya/coremltools 杂散 print 永不污染协议流——比 dup2
  临时重定向更稳）+ `Sources/StreamQuilt/AI/LayaClient.swift`（id 配对并发 in-flight、
  ready/lanes 握手、进程死亡时 fail 全部 in-flight）。
  - **坑：laya 概率在 `r["answers"][q]["probabilities"]`（每个 answer 内），不是顶层
    `r["probabilities"]`**；顶层没有。worker 拍平成 `{"probabilities": {q: {...}}}`。
  - 坑：`Data` 切片经 mutation 后下标偏移——用 `Data(slice)` 重定基拷贝，别用
    `subdata(in:)`（零基假设会炸）。
  - ANE 车道首次加载 ~26s（CoreML 编译，之后有缓存）；运行时 matmul RuntimeWarning
    无害（stderr）。
- **E2**：TrackThemeEngine 加 `brain: .laya/.ollama`。整曲（1024 车道）：theme choice
  12 主题 + emotion choice 14 情感，概率排序取 **top-5 权重池**；逐行（ANE 车道，
  歌词行截 40 字符 + 短指令守 96 token）：对池内 5 主题 pick + 14 情感，
  权重 EMA `0.55w + 0.45p_line` 归一；行情感 +0.15 滞后切换。
  - **坑：hash 兜底是同步完成的，`inFlightTrackID` 必须在 applyFallback 里清掉**，
    否则 laya ready 后重分类被 `id != inFlightTrackID` 永久挡住（症状：reclassify
    日志打了但没有后续 classifying）。
  - laya ready 时若当前曲是 hash 兜底（usedHashFallback），自动重分类拿真概率池。
- **E3**：`ThemeLibrary.swift` 12 主题（蒸汽波/水墨/赛博雨夜/浮世绘/吉卜力/复古航天/
  像素霓虹/印象派/剪纸/低多边形/黑白木刻/敦煌），各带 prompt 片段 + hueBias +
  三元素 gains。prompt 契约 = **采样主题 + 行情感 style + 歌词行(60字符) +
  固定质量尾**（`Theme.qualityTail` = "clean bold shapes, vivid colors, masterpiece"，
  控制词只在尾段、永不进采样）。
- **接线**：sq-ai-demo `--theme-brain laya|ollama`、`--laya-python`、`--laya-models`；
  Studio 默认 laya。引擎内做 2s 节流 + 节拍边界量化（onPrompt 回调），宿主的
  lyricLineChanged 热调制逻辑删除（引擎接管）。Studio G 键 peek 已补（NSEvent
  local monitor，keyCode 5，文本框聚焦时放行；handled 必须 return nil 防 beep）。
- **验收**：build ✓；dump md5 = caaf1d42… ✓；实机 pty 日志：LRCLIB 兜底拉到
  67 行歌词、top-5 池（Roger Waters → cyberpunk-rain 0.37/synthwave 0.31/…）、
  逐行权重漂移、worker prompt 按权重比例采样（impressionist×10/synthwave×2/
  retro×2/cyberpunk×2）、行情感滞后切换（hopeful→serene→romantic）全部生效。
- **调试技巧**：GUI app 的 print 写管道是块缓冲（日志不出），且 `script -q` 在本机
  agent shell 报 "tcgetattr on socket"——用 `python3 -c 'import pty; pty.spawn(...)'`
  给子进程 pty 拿行缓冲实时日志。

### E4 — 验收
- `swift build` 全过；`sq-demo --dump` md5 = caaf1d42f528a58ecd3eeaede99aa554。
- 实机：换曲/行情感切换可见（状态行 🎭 变化 + prompt 日志），60FPS/≥50 tiles/s 不回退。
- lay a worker 随 app 退出清理（SIGTERM 双保险，参考 DiffusionClient.stopAll 教训）。

## 激活提示词（新 session 粘贴）

```
激活 StreamQuilt 的情感引擎×laya 子任务（E1–E4）。

先读恢复上下文（本机）：
1. ~/Desktop/StreamQuilt/docs/emotion-prompt-plan.md ← 本 plan（含 laya 部署现状、
   API、96 token 坑、sidecar 协议要求）
2. ~/Desktop/StreamQuilt/Sources/StreamQuilt/AI/EmotionEngine.swift + OllamaClient.swift
   （Ollama 版 WIP 已接线，HEAD 里；本次把 laya 作为新 brain 接入，参考其接线点）
3. ~/.kimi-code/skills/streamquilt/SKILL.md（全部踩坑：sidecar 清理、多实例、
   display link、PyPI/HF 镜像）
4. ~/Documents/kimi/workspace/laya-coreml/smoke_emotion.py ← laya 调用范例（已验证）

关键上下文：
- laya 是 typed-decision 模型（choice/score/noul），不生成文本；主题扩充走预设表 choice。
- ANE 模型 96 token 总上限（问题+选项+正文），逐行情感用它（~6ms）；整曲主题用
  1024 token 模型（~13ms）。模型加载 7~26s → 必须常驻 sidecar。
- 逐行情感要滞后切换（新概率 > 旧 +0.15 才换）防抖动；行切换已有 2s 节流+节拍量化。
- 硬性约束：60FPS/≥50 tiles/s 不回退；sq-demo --dump md5 回归 caaf1d42…；
  起新实例前 ps aux | grep sq-ai-demo 清残留；git push 用
  env -u ALL_PROXY -u all_proxy git -c http.version=HTTP/1.1 push（网络抖就两种都试）。
```
