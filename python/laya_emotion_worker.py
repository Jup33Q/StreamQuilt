#!/usr/bin/env python3
"""laya emotion sidecar: line-delimited JSON protocol over stdin/stdout.

Loads up to two laya-coreml models ("lanes") and serves typed-decision
requests without respawning (model load is 7-26s — must stay resident).

Request (one JSON object per line on stdin):
  {"id": N, "lane": "track"|"line", "text": "...",
   "questions": {"theme":   {"type": "choice", "criteria": [...], "instructions": "..."},
                 "emotion": {"type": "choice", "criteria": [...], "instructions": "..."}}}

Response (one JSON object per line on stdout):
  {"id": N, "ok": true, "answers": {"theme": "cyberpunk-rain", ...},
   "probabilities": {"theme": {"cyberpunk-rain": 0.61, ...}, ...}}
  or {"id": N, "ok": false, "error": "..."}

Startup: after all requested lanes finish loading, prints
  {"ready": true, "lanes": ["track", "line"]}

Protocol hygiene (see quilt_diffusion_worker.py lessons): stdout is reserved
for protocol frames. fd 1 is dup()ed at start and then aliased to stderr, so
stray prints from laya/coremltools can never corrupt the stream; protocol
frames are written with os.write on the saved fd.

Args:
  --track-model DIR   1024-token model (track-level theme+emotion, ~13ms)
  --line-model DIR    ANE 96-token model (per-lyric-line, ~6ms)
At least one lane is required. Keep requests within the lane's token budget
(ANE: 96 tokens total — short instructions, text pre-truncated by the caller).
"""
import argparse
import json
import os
import sys

# Redirect fd1 -> stderr before importing laya (import-time prints must not
# touch the protocol stream); keep a private fd for protocol frames.
PROTO = os.dup(1)
os.dup2(2, 1)


def send(obj):
    os.write(PROTO, (json.dumps(obj, ensure_ascii=False) + "\n").encode("utf-8"))


def log(*a):
    print(*a, file=sys.stderr, flush=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--track-model", default=None)
    ap.add_argument("--line-model", default=None)
    args = ap.parse_args()
    if not args.track_model and not args.line_model:
        log("need at least one of --track-model / --line-model")
        sys.exit(2)

    import laya_coreml as laya

    agents = {}
    for lane, path in (("track", args.track_model), ("line", args.line_model)):
        if not path:
            continue
        log(f"[laya-worker] loading {lane} model: {path}")
        agents[lane] = laya.load(path)
        log(f"[laya-worker] {lane} model ready")

    send({"ready": True, "lanes": sorted(agents.keys())})

    for raw in sys.stdin:
        raw = raw.strip()
        if not raw:
            continue
        try:
            req = json.loads(raw)
            rid = req["id"]
            lane = req.get("lane", "track")
            agent = agents.get(lane)
            if agent is None:
                send({"id": rid, "ok": False, "error": f"lane '{lane}' not loaded"})
                continue
            r = agent.predict(req["text"], req["questions"])
            answers, probs = {}, {}
            for q, a in r.get("answers", {}).items():
                answers[q] = a.get("choice")
                if a.get("probabilities"):
                    probs[q] = a["probabilities"]
            send({"id": rid, "ok": True, "answers": answers, "probabilities": probs,
                  "truncated": bool(r.get("usage", {}).get("truncated", False))})
        except Exception as e:  # never let one bad request kill the sidecar
            try:
                send({"id": req.get("id", -1), "ok": False,
                      "error": f"{type(e).__name__}: {e}"})
            except Exception:
                send({"id": -1, "ok": False, "error": f"{type(e).__name__}: {e}"})
        sys.stdout.flush()


if __name__ == "__main__":
    main()
