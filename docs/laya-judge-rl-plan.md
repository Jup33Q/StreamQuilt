# Plan: laya 裁判质量 RL 改进（R0→R2）

> 2026-10-05 立项。前置：StreamQuilt S7 已推送（9721a4a）。laya 是 StreamQuilt 情感引擎的
> 裁判模型（曲目→主题/情感/主体/字库四类 choice 决策），本 plan 规划用 RL 方法改进其
> 裁判质量，全程结合本项目的场景与数据资产。

## 现状认知（已核实）

- **laya 本身就是 RL 训的**：convaiinnovations/laya-multilingual（mmBERT-base 322M，
  1024 token，32 option slots），官方训练法 **RLCD**——对 strictly proper scoring
  rules 做强化学习，使"诚实报概率"成为最优策略（概率校准是核心卖点）。
  本地 `models/multilingual/rl_agent_config.json` 实证：`model_name: rl-agent`、
  `act_costs.escalate 0.5`、`cost_wrong_act 3.0`、15987 updates / 4 epochs / ~5h 单卡。
- 因此"RL 改进"= **用本项目的领域奖励延续其原生训练范式**，不是换范式。
- 部署形态：`~/Documents/kimi/workspace/laya-coreml/models/`
  - `multilingual`（CPU+GPU，1024-token **track 车道**）
  - `multilingual-ane`（ANE，96-token **line 车道**）
- 应用侧（`Sources/StreamQuilt/AI/EmotionEngine.swift` TrackThemeEngine）：
  - track 车道 4 问：theme(18)/emotion(14)/fontset(9)/subject(34)；
  - line 车道 2 问：pool pick(≤5)/emotion(14)——**96 token 放不下更多 criteria，
    任何新决策维度只能进 track 车道**；
  - top-5 主题池 EMA(0.55/0.45) 逐行重排；行情感 +0.15 滞回；hash 兜底
    `stableIndex(modulo:)`（modulo 必须跟随目标表大小，越界即崩）；
  - 主体卡曲内每 8 行确定性轮换（零 laya 开销）。
- 数据资产：Music.app 资料库 **555 首**；教师通道 `OllamaClient`
  （127.0.0.1:11434，`gemma4:e4b-mlx`，本机已接线可用）；laya-coreml venv
  `~/Documents/kimi/workspace/laya-coreml/.venv/bin/python`（含 laya_coreml 包 +
  `smoke_emotion.py` fixture 模式 + `validation.json` 出厂校验）。

## 目标

track/line 两个车道的裁判在**主题贴合、情感准确、主体意象**三个维度可度量地变好，
且不损失 laya 的概率校准（ECE 不回退）、不破坏实时性（track 1024 / line 96 token、
ANE 时延不变、hash 兜底不变）。

## 项目特有的可验证奖励（RLVR 信号全在本机）

| 奖励信号 | 来源 | 验证什么 |
|---|---|---|
| 音频特征一致性 | AudioDSP（bass/mid 能量、spectral flux、BPM） | `emotion.energy` 应与实测能量相关；高能量歌判低能量情感 → 罚 |
| track↔line 一致性 | 引擎双车道输出 | 逐行情感分布不应偏离整曲情感太远 |
| 滞回稳定性 | line 情感切换率 vs lyricPace | 非快歌 flip-flop → 罚（线上靠 +0.15 滞回硬压=模型抖动证据） |
| 文本↔主题/主体相关性 | mmBERT/CLIP 文本编码器（本机） | 歌词嵌入 vs theme/subject 短语相似度 |
| 教师标注（RLAIF） | Ollama gemma4:e4b-mlx / 云端大模型 | 主观贴合度最强信号 |
| 行为结果 | 决策日志（快切歌/长看） | 弱噪声在线反馈 |

## 路线图

### R0 评估夹具 + 决策日志（地基，先做）

1. **决策 JSONL 落盘**（TrackThemeEngine）：每次 track 分类记
   `{ts, trackID, name, artist, lyricLines[:4], answers, probabilities, pool, subject, fontset, usedHashFallback}`；
   曲目结束/切换时记 outcome `{trackID, playedSec, durationSec}`（→ 跳过率）。
   写 `logs/decisions.jsonl`（gitignore）。主 runloop 追加写，不进帧路径。
2. **评估夹具**：从 Music 资料库 AppleScript 拉 555 首清单，分层抽 ~120 首
   （中/英/日、摇滚/流行/古典/电子均衡）→ **Ollama 混合裁判初标**（见下）+ 人工复核 →
   `python/laya_judge_fixture.jsonl`（字段：name, artist, theme, emotion, subject, source）。

### 教师混合裁判（gemma + qwen3.8 双评审）

- 双模型独立裁决同一题面（与 app 完全相同的 id 列表）：`gemma4:e4b-mlx`（9.5GB）+
  `qwen3.8:27b-mlx`（18.2GB），均本机 Ollama 已装。中文曲目 qwen 优先参考，
  英/日/多语 gemma 优先参考。
- 一致性规则：
  - **双模型一致** → 直接收录，`source: jury-agree`（高置信）；
  - **不一致** → 进人工复核队列 `source: jury-split`（不重投、不掷硬币——分歧样本
    恰恰是评估集里最有信息量的，必须人来定）；
  - 可选重量级仲裁：本机还有 `gpt-oss:120b`/`gemma4:31b`，分歧量大时再启用。
- 题面要求严格 JSON 输出 {theme, emotion, subject}（Ollama `format: json`），
  非法/超界答案重试 2 次后记 invalid。两模型 temperature 0。
- 产量预估：120 首 × 3 题 × 2 模型 ≈ 720 次调用，本地 M 系列分钟级跑完。
3. **评估器** `python/laya_judge_eval.py`：用 laya-coreml venv 跑**与 app 完全相同的
   问题集**（theme 18/emotion 14/subject 24），输出 top-1/top-3 命中率 + 10 桶 ECE +
   逐类混淆。基线数值记入本 plan。
4. 验收：夹具 ≥100 首；基线报告落盘；日志滚出 ≥20 条真实 episode。

### R1 教师偏好 + 迭代 DPO（性价比最高，先走）

- 用 R0 日志里的真实判例 + 教师标注组偏好对（教师/人工 chosen，laya 错判 rejected），
  对 decision head + encoder LoRA 跑 DPO；多轮迭代（新错例→再标→再训）。
- 约束：**proper scoring rule 保留为辅助 loss**（RLCD 精髓，防校准训丢）；
  line 车道指令长度不变（96 token 是 prompt 侧预算）。
- 验收：夹具 top-1 提升 ≥5pt 且 ECE 不回退；laya-coreml 转换后 `validation.json` 过；
  shadow 模式（新 checkpoint 只记录不生效）线上 A/B ≥2 天再切换。

### R2 GRPO 在线 RL（进阶，原生范式）

- 每曲目 K 温度采样 → 复合奖励（音频一致性 + track↔line KL + 嵌入相似 + 教师分）
  → group-normalize advantage（免 value model）。只训 head+LoRA（322M，MPS 可行；
  上游全量才 5h/单卡）。
- R3 自我一致性正则作常驻奖励项（重复前向 dropout 一致性 + 双车道 KL）。
- 验收：同 R1，且 track↔line 不一致率下降。

## 工程配套

- 训练侧新目录（不在本 repo）：`~/Documents/kimi/workspace/laya-rl/`（数据/脚本/checkpoint），
  转 CoreML 走 `mizorewww/laya-coreml` 转换管线，落 `laya-coreml/models/` 新目录灰度。
- 切换纪律：新 checkpoint 先 shadow ≥2 天；任何回退一键还原目录名；hash 兜底永不动。
- 防退化红线：夹具 ECE 不回退；line 车道 96 token 预算不动；ANE 转换后逐题对比
  CPU 版答案一致率 100%（沿用出厂 fixture 模式）。

## 激活提示词（新 session 粘贴）

```
激活 laya 裁判质量 RL 改进（R0 起步）。

先读恢复上下文（本机）：
1. ~/Desktop/StreamQuilt/docs/laya-judge-rl-plan.md ← 本 plan（现状认知 + 奖励信号表 +
   R0/R1/R2 路线 + 工程配套）
2. ~/Desktop/StreamQuilt/Sources/StreamQuilt/AI/EmotionEngine.swift ← TrackThemeEngine
   （track 车道 4 问 / line 车道 2 问 / top-5 池 EMA / 滞回 / hash 兜底）
3. ~/Desktop/StreamQuilt/Sources/StreamQuilt/AI/ThemeLibrary.swift ← Theme.all=18 +
   SubjectPool=34（夹具的答案空间）
4. ~/.kimi-code/skills/streamquilt/SKILL.md（laya 概率位置、modulo 越界坑、ANE 车道预算）

关键上下文：
- laya = convaiinnovations/laya-multilingual（mmBERT 322M），官方 RLCD 训练（对
  strictly proper scoring rules 做 RL）；本地 rl_agent_config.json 实证。改进=延续
  其原生 RL 范式，proper scoring rule 必须留作辅助 loss 防校准训丢。
- 模型在 ~/Documents/kimi/workspace/laya-coreml/models/{multilingual(1024 token track
  车道), multilingual-ane(96 token ANE line 车道)}；venv 在同目录 .venv（含
  laya_coreml 包 + smoke_emotion.py fixture 模式）。
- 教师：**Ollama 混合裁判 gemma4:e4b-mlx(9.5GB) + qwen3.8:27b-mlx(18.2GB)**，
  双模型独立裁决同题面；jury-agree 直接收录、jury-split 进人工复核（规则见 plan
  「教师混合裁判」节）；本机还有 gpt-oss:120b/gemma4:31b 作重量级备选仲裁。
  Music 资料库 555 首。
- R0 三件事：TrackThemeEngine 决策 JSONL 落盘（logs/decisions.jsonl，gitignore）；
  从 Music 库分层抽 ~120 首做 python/laya_judge_fixture.jsonl（混合裁判初标+人工复核）；
  python/laya_judge_eval.py 跑 app 同构问题集出 top-1/top-3/ECE 基线。
- 约束：line 车道 96 token 永不加 criteria；stableIndex modulo 跟随目标表；
  新 checkpoint 先 shadow ≥2 天再切换；hash 兜底不动。
- 完成后 R1（迭代 DPO，教师偏好对）→ R2（GRPO 复合奖励），验收标准见 plan。
```
