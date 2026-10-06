# laya judge baseline (2026-10-05 21:33)

- model: `/Users/jup33q/Documents/kimi/workspace/laya-coreml/models/multilingual`
- fixture: `python/laya_judge_fixture.jsonl` — 120 labeled tracks

## theme

- n=120  top-1: **0.100**  top-3: **0.233**  ECE(10): **0.3149**

- top confusions: watercolor→synthwave×23, woodcut-bw→synthwave×11, ink-wash→synthwave×10, cyberpunk-rain→synthwave×8, watercolor→ghibli-pastoral×5

## emotion

- n=120  top-1: **0.175**  top-3: **0.425**  ECE(10): **0.3068**

- top confusions: melancholic→lonely×5, rebellious→joyful×5, melancholic→romantic×4, hopeful→joyful×4, dreamy→joyful×3

## subject_cat

- n=120  top-1: **0.258**  top-3: **0.642**  ECE(10): **0.4706**

- top confusions: architecture→people×22, animal→people×14, vehicle→people×9, animal→vehicle×8, people→vehicle×7

## subject(card|pred-cat)

- n=120  top-1: **0.108**  top-3: **0.200**  ECE(10): **0.4582**

- top confusions: skywhale→wanderer×6, neontower→wanderer×6, skywhale→zeppelin×5, ruins→crane×4, wanderer→witch×4

## reference

- chance top-1: theme 1/18=0.056, emotion 1/14=0.071, subject_cat 1/5=0.2, card ~1/6.8

