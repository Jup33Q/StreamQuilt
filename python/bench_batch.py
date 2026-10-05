#!/usr/bin/env python3
"""Batch-mode benchmark: one worker with --batch 4, measure tiles/s."""
import os
import struct
import subprocess
import sys
import time

import numpy as np

PY = os.path.expanduser("~/Documents/kimi/workspace/streamdiffusion-mac/.venv/bin/python")
SCRIPT = os.path.expanduser("~/Desktop/StreamQuilt/python/quilt_diffusion_worker.py")


def read_exact(f, n):
    d = b""
    while len(d) < n:
        c = f.read(n - len(d))
        if not c:
            raise RuntimeError("EOF")
        d += c
    return d


def main():
    batch = int(sys.argv[1]) if len(sys.argv) > 1 else 4
    units = sys.argv[2] if len(sys.argv) > 2 else "all"
    env = {"PATH": "/usr/bin:/bin", "HF_HUB_OFFLINE": "1"}
    p = subprocess.Popen([PY, SCRIPT, "--worker-id", "0", "--compute-units", units,
                          "--batch", str(batch)],
                         stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                         stderr=subprocess.DEVNULL, env=env)
    hdr = struct.unpack("<III", read_exact(p.stdout, 12))
    assert hdr[0] == 0xFFFFFFFE
    print("ready")

    rng = np.random.RandomState(0)
    frames = [(rng.rand(512, 512, 3) * 255).astype(np.uint8).tobytes() for _ in range(batch)]

    count = 0
    t0 = time.time()
    rounds = 0
    while time.time() - t0 < 12:
        # push batch frames back-to-back, then read batch results
        for i in range(batch):
            p.stdin.write(struct.pack("<III", i, 512, 512) + frames[i])
        p.stdin.flush()
        for i in range(batch):
            v, w, h = struct.unpack("<III", read_exact(p.stdout, 12))
            read_exact(p.stdout, w * h * 4)
            count += 1
        rounds += 1
    dt = time.time() - t0
    print(f"batch={batch} units={units}: {count} imgs in {dt:.1f}s -> {count / dt:.1f} tiles/s "
          f"({dt / rounds * 1000:.0f}ms per batch of {batch})")
    p.terminate()


if __name__ == "__main__":
    main()
