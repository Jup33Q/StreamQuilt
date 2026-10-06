#!/usr/bin/env python3
"""Build the laya judge fixture (R0 of docs/laya-judge-rl-plan.md).

Stages (run in order; each is resumable / idempotent):

  dump    AppleScript-pull the Music.app library (name/artist/album/genre/
          duration) -> python/music_library.jsonl
  sample  stratified ~N tracks (language x genre bucket) ->
          python/laya_judge_candidates.jsonl
  lyrics  LRCLIB first-4 lyric lines for each candidate (app judge text
          includes them when available) -> updated candidates file
  jury    dual-teacher labeling (gemma4:e4b-mlx + qwen3.8:27b-mlx, strict
          JSON, temperature 0, <=2 retries) -> python/laya_judge_fixture.jsonl
          jury-agree = both models identical on all 3 fields (high trust)
          jury-split = any disagreement -> human review queue (source field)

Stdlib only. Ollama at 127.0.0.1:11434. Proxies are bypassed for localhost
calls; LRCLIB tries direct first, env-proxy as fallback.
"""
import json
import os
import random
import re
import subprocess
import sys
import time
import urllib.parse
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from laya_judge_data import (THEMES, EMOTIONS, SUBJECTS, CATEGORIES,
                             THEME_IDS, EMOTION_IDS, SUBJECT_IDS, track_text)

HERE = os.path.dirname(os.path.abspath(__file__))
LIBRARY = os.path.join(HERE, "music_library.jsonl")
CANDIDATES = os.path.join(HERE, "laya_judge_candidates.jsonl")
FIXTURE = os.path.join(HERE, "laya_judge_fixture.jsonl")

OLLAMA = "http://127.0.0.1:11434"
JUDGES = ["gemma4:e4b-mlx", "qwen3.8:27b-mlx"]

NO_PROXY = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def read_jsonl(path):
    if not os.path.exists(path):
        return []
    with open(path, encoding="utf-8") as f:
        return [json.loads(l) for l in f if l.strip()]


def append_jsonl(path, obj):
    with open(path, "a", encoding="utf-8") as f:
        f.write(json.dumps(obj, ensure_ascii=False, sort_keys=True) + "\n")


# ---------------------------------------------------------------- dump

DUMP_SCRIPT = r"""
set delim to tab
set out to ""
tell application "Music"
    repeat with t in tracks of library playlist 1
        try
            set out to out & (name of t) & delim & (artist of t) & delim ¬
                & (album of t) & delim & (genre of t) & delim & (time of t) & linefeed
        end try
    end repeat
end tell
return out
"""


def stage_dump():
    script = os.path.join(HERE, ".dump_library.scpt")
    with open(script, "w", encoding="utf-8") as f:
        f.write(DUMP_SCRIPT)
    try:
        raw = subprocess.run(["osascript", script], capture_output=True,
                             text=True, timeout=600)
    finally:
        os.unlink(script)
    if raw.returncode != 0:
        sys.exit(f"osascript failed: {raw.stderr.strip()}")
    n = 0
    with open(LIBRARY, "w", encoding="utf-8") as f:
        for line in raw.stdout.splitlines():
            parts = line.split("\t")
            if len(parts) < 5 or not parts[0].strip():
                continue
            name, artist, album, genre, dur = (p.strip() for p in parts[:5])
            if genre in ("missing value",):
                genre = ""
            rec = {"name": name, "artist": artist, "album": album,
                   "genre": genre, "duration": dur}
            f.write(json.dumps(rec, ensure_ascii=False, sort_keys=True) + "\n")
            n += 1
    print(f"dumped {n} tracks -> {LIBRARY}")


# ---------------------------------------------------------------- sample

GENRE_BUCKETS = [
    ("rock", re.compile(r"rock|metal|punk|indie|alternative|grunge", re.I)),
    ("pop", re.compile(r"pop|k-pop|j-pop|mandopop|cantopop|teen", re.I)),
    ("electronic", re.compile(r"electro|techno|house|dance|edm|trance|dubstep|drum|synth", re.I)),
    ("classical", re.compile(r"classical|soundtrack|score|orchestra|piano|instrumental|new age|ambient", re.I)),
    ("hiphop", re.compile(r"hip.?hop|rap|trap|r&b|soul|funk", re.I)),
    ("folk", re.compile(r"folk|country|acoustic|singer|ballad|jazz|blues", re.I)),
]

CJK = re.compile(r"[一-鿿　-〿＀-￯]")
KANA = re.compile(r"[぀-ヿ]")


def lang_of(rec):
    s = rec["name"] + " " + rec["artist"]
    if KANA.search(s):
        return "ja"
    if CJK.search(s):
        return "zh"
    return "en"


def bucket_of(rec):
    g = rec["genre"] or ""
    for name, rx in GENRE_BUCKETS:
        if rx.search(g):
            return name
    return "other"


def stage_sample(target):
    lib = read_jsonl(LIBRARY)
    if not lib:
        sys.exit("run dump first")
    random.seed(20261005)
    strata = {}
    for rec in lib:
        key = (lang_of(rec), bucket_of(rec))
        strata.setdefault(key, []).append(rec)
    for v in strata.values():
        random.shuffle(v)
    picked = []
    # proportional allocation with at least 1 per non-empty stratum
    total = len(lib)
    quotas = {k: max(1, round(len(v) / total * target)) for k, v in strata.items()}
    while sum(quotas.values()) > target:
        k = max(quotas, key=lambda k: quotas[k])
        if quotas[k] > 1:
            quotas[k] -= 1
        else:
            break
    for k, q in quotas.items():
        picked.extend(strata[k][:q])
    random.shuffle(picked)
    out = []
    with open(CANDIDATES, "w", encoding="utf-8") as f:
        for rec in picked:
            rec = dict(rec, lang=lang_of(rec), bucket=bucket_of(rec),
                       lyricLines=[])
            out.append(rec)
            f.write(json.dumps(rec, ensure_ascii=False, sort_keys=True) + "\n")
    from collections import Counter
    print(f"sampled {len(out)} -> {CANDIDATES}")
    print("  lang:", dict(Counter(r["lang"] for r in out)))
    print("  bucket:", dict(Counter(r["bucket"] for r in out)))


# ---------------------------------------------------------------- lyrics

LRC_TS = re.compile(r"\[[0-9]+:[0-9]+(?:\.[0-9]+)?\]")


def mmss_to_sec(s):
    try:
        m, sec = s.split(":")
        return int(m) * 60 + int(sec)
    except Exception:
        return 0


def fetch_lyrics(rec):
    q = urllib.parse.urlencode({
        "track_name": rec["name"], "artist_name": rec["artist"],
        "album_name": rec["album"], "duration": mmss_to_sec(rec["duration"]),
    })
    url = "https://lrclib.net/api/get?" + q
    req = urllib.request.Request(url, headers={
        "User-Agent": "StreamQuilt-laya-fixture/0.1 (local eval fixture)"})
    for opener in (NO_PROXY, urllib.request.build_opener()):
        try:
            with opener.open(req, timeout=12) as r:
                obj = json.loads(r.read().decode("utf-8"))
            lines = []
            src = obj.get("syncedLyrics") or ""
            for l in src.splitlines():
                t = LRC_TS.sub("", l).strip()
                if t:
                    lines.append(t)
                if len(lines) >= 4:
                    break
            if not lines:
                for l in (obj.get("plainLyrics") or "").splitlines():
                    if l.strip():
                        lines.append(l.strip())
                    if len(lines) >= 4:
                        break
            return lines
        except Exception:
            continue
    return None


def stage_lyrics():
    cands = read_jsonl(CANDIDATES)
    if not cands:
        sys.exit("run sample first")

    def save():
        with open(CANDIDATES, "w", encoding="utf-8") as f:
            for r in cands:
                f.write(json.dumps(r, ensure_ascii=False, sort_keys=True) + "\n")

    got = 0
    for i, rec in enumerate(cands):
        if rec.get("lyricLines"):
            got += 1
            continue
        lines = fetch_lyrics(rec)
        if lines is None:
            print(f"  [{i + 1}/{len(cands)}] MISS {rec['name']} — {rec['artist']}",
                  flush=True)
        else:
            rec["lyricLines"] = lines
            got += 1
            save()   # persist incrementally — survives timeouts
        time.sleep(0.3)
    save()
    print(f"lyrics for {got}/{len(cands)} candidates")


# ---------------------------------------------------------------- jury

def judge_prompt(rec):
    text = track_text(rec["name"], rec["artist"], rec["album"], rec["genre"],
                      rec.get("lyricLines", []))
    theme_list = "\n".join(f"- {tid} ({zh}): {desc}" for tid, zh, desc in THEMES)
    emo_list = ", ".join(f"{eid}({zh})" for eid, zh in EMOTIONS)
    subj_list = "\n".join(f"- {sid} [{cat}] ({zh}): {desc}"
                          for sid, zh, cat, desc in SUBJECTS)
    return f"""你是音乐可视化系统的标注员。根据歌曲信息，从给定 id 列表中各选一个最贴切的答案。

歌曲信息: {text}

theme（视觉艺术主题，从下列 id 中选一个）:
{theme_list}

emotion（歌曲主导情绪，从下列 id 中选一个）:
{emo_list}

subject（与歌曲意象最贴合的前景主体，从下列 id 中选一个）:
{subj_list}

只输出 JSON，不要输出任何其他内容:
{{"theme":"<id>","emotion":"<id>","subject":"<id>"}}"""


def judge_call(model, prompt):
    body = json.dumps({
        "model": model, "prompt": prompt, "stream": False,
        "format": "json", "think": False, "keep_alive": "30m",
        "options": {"temperature": 0, "num_predict": 512},
    }).encode("utf-8")
    req = urllib.request.Request(OLLAMA + "/api/generate", data=body,
                                 headers={"Content-Type": "application/json"})
    with NO_PROXY.open(req, timeout=300) as r:
        return json.loads(r.read().decode("utf-8")).get("response", "")


def pick_id(v, ids):
    """Models sometimes echo the prompt's display string ("ink-wash (水墨山水)",
    "wanderer [people] (提灯旅人)") instead of the bare id — recover the id."""
    if not isinstance(v, str):
        return None
    v = v.strip().lower()
    if v in ids:
        return v
    for i in ids:
        if v.startswith(i + " ") or v.startswith(i + "(") or v.startswith(i + "["):
            return i
    return None


def judge_parse(raw):
    m = re.search(r"\{.*\}", raw, re.S)
    if not m:
        return None
    try:
        obj = json.loads(m.group(0))
    except Exception:
        return None
    t = pick_id(obj.get("theme"), THEME_IDS)
    e = pick_id(obj.get("emotion"), EMOTION_IDS)
    s = pick_id(obj.get("subject"), SUBJECT_IDS)
    if t and e and s:
        return {"theme": t, "emotion": e, "subject": s}
    return None


def judge_track(rec):
    prompt = judge_prompt(rec)
    out = {}
    for model in JUDGES:
        ans = None
        for _ in range(3):   # initial + 2 retries on invalid/out-of-range
            try:
                ans = judge_parse(judge_call(model, prompt))
            except Exception as ex:
                print(f"    {model} error: {ex}")
            if ans:
                break
        out[model] = ans
    return out


def stage_jury():
    cands = read_jsonl(CANDIDATES)
    if not cands:
        sys.exit("run sample first")
    done = {r["name"] + " — " + r["artist"] for r in read_jsonl(FIXTURE)}
    todo = [r for r in cands if r["name"] + " — " + r["artist"] not in done]
    print(f"jury: {len(done)} done, {len(todo)} to go")
    for i, rec in enumerate(todo):
        tid = rec["name"] + " — " + rec["artist"]
        jury = judge_track(rec)
        a, b = jury[JUDGES[0]], jury[JUDGES[1]]
        # per-FIELD agreement: an agreed field is high-trust even when the
        # other fields split (full-record agreement is too strict for 3
        # subjective fields and would yield almost no labels)
        fields, field_sources = {}, {}
        for f in ("theme", "emotion", "subject"):
            va = a.get(f) if a else None
            vb = b.get(f) if b else None
            if va is not None and va == vb:
                fields[f] = va
                field_sources[f] = "jury-agree"
            else:
                fields[f] = None
                field_sources[f] = "jury-split" if (va and vb) else "jury-invalid"
        agree_all = all(v == "jury-agree" for v in field_sources.values())
        rec_out = {
            "name": rec["name"], "artist": rec["artist"],
            "album": rec["album"], "genre": rec["genre"],
            "duration": rec["duration"], "lang": rec.get("lang", ""),
            "bucket": rec.get("bucket", ""),
            "lyricLines": rec.get("lyricLines", []),
            "theme": fields["theme"],
            "emotion": fields["emotion"],
            "subject": fields["subject"],
            "fieldSources": field_sources,
            "source": "jury-agree" if agree_all else "jury-split",
            "jury": jury,
        }
        append_jsonl(FIXTURE, rec_out)
        n_agree_f = sum(1 for v in field_sources.values() if v == "jury-agree")
        print(f"  [{i + 1}/{len(todo)}] {n_agree_f}/3 {tid}"
              + ("" if agree_all else f"  gemma={a} qwen={b}"), flush=True)
    allr = read_jsonl(FIXTURE)
    n_full = sum(1 for r in allr if r["source"] == "jury-agree")
    n_fields = sum(sum(1 for v in r["fieldSources"].values() if v == "jury-agree")
                   for r in allr)
    print(f"fixture: {len(allr)} tracks, {n_full} full-agree, "
          f"{n_fields}/{len(allr) * 3} field-agrees")


# ---------------------------------------------------------------- arbitrate

ARBITER = "gemma4:31b"   # heavyweight tie-breaker; gpt-oss:120b as --arbiter


def arbitrate_prompt(rec, splits):
    text = track_text(rec["name"], rec["artist"], rec["album"], rec["genre"],
                      rec.get("lyricLines", []))
    lines = []
    for f, (va, vb) in splits.items():
        lines.append(f'- {f}: A) {va}   B) {vb}')
    keys = ",".join(f'"{f}":"A或B"' for f in splits)
    return f"""你是音乐可视化标注的仲裁员。两位标注员对同一首歌给出了不同答案，请选择更贴切的一个。

歌曲信息: {text}

分歧字段（只能从 A/B 中选）:
{chr(10).join(lines)}

只输出 JSON，不要输出任何其他内容:
{{{keys}}}"""


def stage_arbitrate(arbiter):
    recs = read_jsonl(FIXTURE)
    if not recs:
        sys.exit("run jury first")
    n_done = n_new = 0
    for i, rec in enumerate(recs):
        jury = rec.get("jury") or {}
        a, b = jury.get(JUDGES[0]) or {}, jury.get(JUDGES[1]) or {}
        splits = {}
        for f in ("theme", "emotion", "subject"):
            if (rec.get("fieldSources", {}).get(f) == "jury-split"
                    and a.get(f) and b.get(f)):
                splits[f] = (a[f], b[f])
        if not splits:
            continue
        prompt = arbitrate_prompt(rec, splits)
        picked = None
        for _ in range(3):
            try:
                raw = judge_call(arbiter, prompt)
                m = re.search(r"\{.*\}", raw, re.S)
                obj = json.loads(m.group(0)) if m else {}
                picked = {f: str(obj.get(f, "")).strip().upper() for f in splits}
                if all(picked[f] in ("A", "B") for f in splits):
                    break
                picked = None
            except Exception as ex:
                print(f"    arbiter error: {ex}", flush=True)
        if picked is None:
            print(f"  [{i + 1}] ARBITER-INVALID {rec['name']}", flush=True)
            continue
        arb = rec.setdefault("arbitration", {})
        for f, (va, vb) in splits.items():
            choice = va if picked[f] == "A" else vb
            rec[f] = choice
            rec["fieldSources"][f] = f"jury-arbiter:{arbiter}"
            arb[f] = {"A": va, "B": vb, "picked": picked[f]}
        n_new += 1
        print(f"  [{i + 1}/{len(recs)}] arbitrated {rec['name']} — {rec['artist']}"
              f"  {picked}", flush=True)
        # incremental save (long stage; survives interruption)
        with open(FIXTURE, "w", encoding="utf-8") as fh:
            for r in recs:
                fh.write(json.dumps(r, ensure_ascii=False, sort_keys=True) + "\n")
        n_done += 1
    print(f"arbitrated {n_new} records with {arbiter}")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    stage = sys.argv[1]
    if stage == "dump":
        stage_dump()
    elif stage == "sample":
        stage_sample(int(sys.argv[2]) if len(sys.argv) > 2 else 120)
    elif stage == "lyrics":
        stage_lyrics()
    elif stage == "jury":
        stage_jury()
    elif stage == "arbitrate":
        stage_arbitrate(sys.argv[2] if len(sys.argv) > 2 else ARBITER)
    else:
        sys.exit(f"unknown stage {stage!r}")
