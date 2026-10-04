#!/usr/bin/env python3
"""M0 baseline: measure single-frame CoreML img2img latency of the StreamDiffusion
pipeline on this machine, using the models/ dir of this repo.

Usage:
    .venv-python bench_coreml_pipeline.py [--frames 60] [--render-size 512]
"""
import argparse
import os
import sys
import time

import numpy as np

SD_MAC_PYTHON = os.environ.get(
    "SD_MAC_PYTHON",
    os.path.expanduser("~/Documents/kimi/workspace/streamdiffusion-mac/python"),
)
sys.path.insert(0, SD_MAC_PYTHON)
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--frames", type=int, default=60)
    ap.add_argument("--render-size", type=int, default=512)
    ap.add_argument("--strength", type=float, default=0.45)
    ap.add_argument("--coreml-dir", default=os.path.join(
        os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "models"))
    args = ap.parse_args()

    from pipelines.coreml import Pipeline

    t0 = time.time()
    pipe = Pipeline(
        model_name="sdxs", render_size=args.render_size, output_size=args.render_size,
        prompt="vaporwave ukiyo-e woodblock print style, neon pastel city, masterpiece",
        strength=args.strength, prompts=None, latent_feedback=0.15,
        coreml_dir=args.coreml_dir, seed=42,
    )
    init_s = time.time() - t0
    print(f"[bench] init: {init_s:.1f}s")

    rng = np.random.RandomState(0)
    frame = (rng.rand(args.render_size, args.render_size, 3) * 255).astype(np.uint8)

    # warmup already done in __init__; measure steady-state
    times = []
    for i in range(args.frames):
        t = time.time()
        out = pipe.process_frame_rgb(frame)
        times.append((time.time() - t) * 1000)
    times = np.array(times)
    print(f"[bench] {args.render_size}px strength={args.strength}: "
          f"avg {times.mean():.1f}ms  p50 {np.median(times):.1f}  "
          f"min {times.min():.1f}  max {times.max():.1f}  "
          f"-> {1000.0 / times.mean():.1f} img/s per worker")
    print(f"[bench] projected 66-view full sweep with 1/2/4 workers: "
          f"{66 * times.mean() / 1000:.2f}s / {66 * times.mean() / 2000:.2f}s / "
          f"{66 * times.mean() / 4000:.2f}s")
    assert out.shape == (args.render_size, args.render_size, 3)


if __name__ == "__main__":
    main()
