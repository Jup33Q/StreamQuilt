#!/usr/bin/env python3
"""Concurrency benchmark: N quilt_diffusion_workers, continuous feed per worker,
measure aggregate tiles/s. Tests compute-unit assignment strategies.

Usage:
    python bench_concurrent.py --workers 2 --units all,cpu_and_gpu --seconds 12
"""
import argparse
import os
import struct
import subprocess
import sys
import threading
import time

import numpy as np

PY = os.path.expanduser("~/Documents/kimi/workspace/streamdiffusion-mac/.venv/bin/python")
SCRIPT = os.path.expanduser("~/Desktop/lkg-metal-quilt/python/quilt_diffusion_worker.py")


def read_exact(f, n):
    d = b""
    while len(d) < n:
        c = f.read(n - len(d))
        if not c:
            raise RuntimeError("EOF")
        d += c
    return d


def worker_proc(idx, units, seconds, results, render_size):
    env = {"PATH": "/usr/bin:/bin", "HF_HUB_OFFLINE": "1"}
    p = subprocess.Popen([PY, SCRIPT, "--worker-id", str(idx), "--compute-units", units,
                          "--render-size", str(render_size)],
                         stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                         stderr=subprocess.DEVNULL, env=env)
    # wait beacon
    hdr = struct.unpack("<III", read_exact(p.stdout, 12))
    assert hdr[0] == 0xFFFFFFFE
    ready_at = time.time()

    rng = np.random.RandomState(idx)
    frame = (rng.rand(render_size, render_size, 3) * 255).astype(np.uint8).tobytes()
    hdr_out = struct.pack("<III", 0, render_size, render_size)

    count = 0
    end = time.time() + seconds
    while time.time() < end:
        p.stdin.write(hdr_out + frame)
        p.stdin.flush()
        v, w, h = struct.unpack("<III", read_exact(p.stdout, 12))
        read_exact(p.stdout, w*h*4)
        count += 1
    results[idx] = (count, ready_at)
    p.terminate()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--workers", type=int, default=2)
    ap.add_argument("--units", type=str, default="all,all")
    ap.add_argument("--seconds", type=float, default=12)
    ap.add_argument("--render-size", type=int, default=512)
    args = ap.parse_args()

    units = args.units.split(",")
    assert len(units) == args.workers

    results = {}
    t0 = time.time()
    threads = [threading.Thread(target=worker_proc,
                                args=(i, units[i], args.seconds, results, args.render_size))
               for i in range(args.workers)]
    for t in threads: t.start()
    for t in threads: t.join()
    total = sum(c for c, _ in results.values())
    elapsed = max(time.time() - t0 - (results[i][1] - t0) for i in results) if results else 1
    print(f"units={args.units}: total {total} imgs, "
          f"aggregate {total / args.seconds:.1f} tiles/s "
          f"(per-worker {[f'{c / args.seconds:.1f}' for c, _ in results.values()]})")


if __name__ == "__main__":
    main()
