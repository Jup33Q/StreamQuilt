#!/usr/bin/env python3
"""laya judge baseline evaluator (R0-3 of docs/laya-judge-rl-plan.md).

Runs the laya judge over the fixture with the APP-IDENTICAL question set
(theme 18 / emotion 14 / subject_cat 5 / fontset 9 in one track-lane call,
then a second call for the in-category subject card) and reports:

  top-1 / top-3 accuracy per question, 10-bucket ECE (probability
  calibration — must not regress in R1/R2), top confusion pairs.

Usage (laya-coreml venv python):
  .venv/bin/python .../laya_judge_eval.py \
      --fixture .../python/laya_judge_fixture.jsonl \
      --model   .../models/multilingual \
      [--limit N] [--out-md docs/laya-judge-baseline.md] \
      [--out-json python/laya_judge_baseline.json]

Only records with all three labels (source jury-agree, or human-resolved)
are scored. Subject card accuracy is app-isomorphic: stage 2 arbitrates
inside the model's OWN predicted category (a wrong cat caps the card).
"""
import argparse
import json
import os
import sys
import time
from collections import Counter

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from laya_judge_data import (THEME_IDS, EMOTION_IDS, CATEGORIES, FONTSET_IDS,
                             INS_THEME, INS_EMOTION, INS_SUBJECT_CAT,
                             INS_SUBJECT, INS_FONTSET,
                             SUBJECT_CAT, cards_of, track_text)

import laya_coreml as laya


def probs_of(r, q):
    """laya_coreml >=0.2 returns top-level r['probabilities'][q]; older
    builds nest probabilities inside each answer. Handle both."""
    p = (r.get("probabilities") or {}).get(q)
    if p:
        return p
    a = (r.get("answers") or {}).get(q)
    if isinstance(a, dict):
        return a.get("probabilities") or {}
    return {}


def answer_of(r, q):
    a = (r.get("answers") or {}).get(q)
    if isinstance(a, dict):
        return a.get("choice") or a.get("answer")
    return a


def topk(probs, k):
    return [c for c, _ in sorted(probs.items(), key=lambda kv: -kv[1])[:k]]


def ece10(records):
    """records: list of (confidence, correct). 10 equal-width bins."""
    bins = [[] for _ in range(10)]
    for conf, ok in records:
        bins[min(int(conf * 10), 9)].append((conf, ok))
    ece, out = 0.0, []
    n = len(records)
    for i, b in enumerate(bins):
        if not b:
            continue
        acc = sum(1 for _, ok in b if ok) / len(b)
        conf = sum(c for c, _ in b) / len(b)
        ece += len(b) / n * abs(acc - conf)
        out.append({"bin": f"{i / 10:.1f}-{i / 10 + 0.1:.1f}", "n": len(b),
                    "acc": round(acc, 3), "conf": round(conf, 3)})
    return round(ece, 4), out


def metric(records, golds, k=1):
    hits = sum(1 for rec, gold in zip(records, golds) if gold in rec[:k])
    return round(hits / max(len(golds), 1), 4)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--fixture", required=True)
    ap.add_argument("--model", required=True)
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--out-md", default="")
    ap.add_argument("--out-json", default="")
    args = ap.parse_args()

    recs = [json.loads(l) for l in open(args.fixture, encoding="utf-8")
            if l.strip()]
    # a record is worth predicting on when at least one field is labeled
    # (per-field jury agreement: split records still contribute agreed fields)
    labeled = [r for r in recs
               if r.get("theme") or r.get("emotion") or r.get("subject")]
    if args.limit:
        labeled = labeled[:args.limit]
    if not labeled:
        sys.exit("no labeled records (jury-agree / human) in fixture")
    print(f"evaluating {len(labeled)} tracks with >=1 label "
          f"(of {len(recs)} in fixture)")

    t0 = time.time()
    agent = laya.load(args.model)
    print(f"loaded {args.model} in {time.time() - t0:.1f}s")

    rows = []
    for i, rec in enumerate(labeled):
        text = track_text(rec["name"], rec["artist"], rec.get("album", ""),
                          rec.get("genre", ""), rec.get("lyricLines", []))
        r1 = agent.predict(text, {
            "theme": {"type": "choice", "criteria": THEME_IDS,
                      "instructions": INS_THEME},
            "emotion": {"type": "choice", "criteria": EMOTION_IDS,
                        "instructions": INS_EMOTION},
            "subject_cat": {"type": "choice", "criteria": CATEGORIES,
                            "instructions": INS_SUBJECT_CAT},
            "fontset": {"type": "choice", "criteria": FONTSET_IDS,
                        "instructions": INS_FONTSET},
        })
        pred_cat = answer_of(r1, "subject_cat")
        if pred_cat not in CATEGORIES:
            pred_cat = CATEGORIES[0]
        # stage 2: card arbitration inside the predicted category (app path)
        r2 = agent.predict(text, {
            "subject": {"type": "choice", "criteria": cards_of(pred_cat),
                        "instructions": INS_SUBJECT},
        })
        rows.append({
            "rec": rec,
            "theme": answer_of(r1, "theme"), "theme_p": probs_of(r1, "theme"),
            "emotion": answer_of(r1, "emotion"), "emotion_p": probs_of(r1, "emotion"),
            "subject_cat": pred_cat, "cat_p": probs_of(r1, "subject_cat"),
            "subject": answer_of(r2, "subject"),
            "subject_p": probs_of(r2, "subject"),
        })
        if (i + 1) % 10 == 0:
            print(f"  {i + 1}/{len(labeled)}")

    report = {"n": len(rows), "model": args.model,
              "fixture": args.fixture, "ts": time.time()}
    md = [f"# laya judge baseline ({time.strftime('%Y-%m-%d %H:%M')})",
          f"\n- model: `{args.model}`",
          f"- fixture: `{args.fixture}` — {len(rows)} labeled tracks\n"]

    def question(name, pred_key, prob_key, gold_fn):
        # per-question subset: only rows whose gold field is labeled
        sub = [(row, gold_fn(row["rec"])) for row in rows]
        sub = [(row, g) for row, g in sub if g]
        golds = [g for _, g in sub]
        tops1 = [topk(row[prob_key], 1) for row, _ in sub]
        tops3 = [topk(row[prob_key], 3) for row, _ in sub]
        ece, bins = ece10([
            (row[prob_key].get(row[pred_key], 0.0),
             row[pred_key] == gold)
            for row, gold in sub])
        res = {"n": len(sub),
               "top1": metric(tops1, golds, 1),
               "top3": metric(tops3, golds, 3), "ece10": ece, "bins": bins}
        conf = Counter((g, row[pred_key])
                       for row, g in sub if row[pred_key] != g)
        res["confusions"] = [{"gold": g, "pred": p, "n": n}
                             for (g, p), n in conf.most_common(8)]
        report[name] = res
        md.append(f"## {name}\n")
        md.append(f"- n={res['n']}  top-1: **{res['top1']:.3f}**  "
                  f"top-3: **{res['top3']:.3f}**  ECE(10): **{res['ece10']:.4f}**\n")
        if res["confusions"]:
            md.append("- top confusions: " + ", ".join(
                f"{c['gold']}→{c['pred']}×{c['n']}" for c in res["confusions"][:5]) + "\n")
        return res

    question("theme", "theme", "theme_p", lambda r: r["theme"])
    question("emotion", "emotion", "emotion_p", lambda r: r["emotion"])
    question("subject_cat", "subject_cat", "cat_p",
             lambda r: SUBJECT_CAT[r["subject"]])
    # card: app-isomorphic (stage 2 ran inside the predicted category);
    # top-3 is within that category's card list
    question("subject(card|pred-cat)", "subject", "subject_p",
             lambda r: r["subject"])

    # chance levels for context
    md.append("## reference\n")
    md.append(f"- chance top-1: theme 1/18=0.056, emotion 1/14=0.071, "
              f"subject_cat 1/5=0.2, card ~1/6.8\n")

    text_md = "\n".join(md)
    if args.out_md:
        with open(args.out_md, "w", encoding="utf-8") as f:
            f.write(text_md + "\n")
    if args.out_json:
        slim = dict(report)
        with open(args.out_json, "w", encoding="utf-8") as f:
            json.dump(slim, f, ensure_ascii=False, indent=1)
    print(text_md)


if __name__ == "__main__":
    main()
