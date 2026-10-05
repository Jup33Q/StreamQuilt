#!/usr/bin/env python3
"""
Quilt diffusion worker — per-view StreamDiffusion img2img backend for sq-ai-demo.

Reads per-view RGB frames from stdin, stylizes them with the CoreML img2img
pipeline (streamdiffusion-mac), and writes raw RGB results to stdout.

Wire protocol (all little-endian, no length prefix wrapper):

  Input frame:  <<view_index::u32, width::u32, height::u32, rgb[w*h*3],
                  depth[w*h]>>  (depth 0 = near/preserve, 255 = far/free; the
                  sender always transmits it, all-0xFF = uniform legacy noise)
  Input prompt: <<0xFFFFFFFF::u32, prompt_len::u32, prompt_bytes>>
  Input seed:   <<0xFFFFFFFD::u32, seed::u32, 0::u32>>
  Output frame: <<view_index::u32, width::u32, height::u32, rgba[w*h*4]>>
  Ready beacon: <<0xFFFFFFFE::u32, pid::u32, tid::u32>>

Per-view state: the pipeline's latent-feedback buffer (`_prev_denoised`) is
swapped per view so temporal coherence never leaks across views. The base
noise is fixed per seed, which keeps the 66 views stylistically consistent.

Env:
    SD_MAC_PYTHON — path to streamdiffusion-mac/python (default: sibling repo
                    checkout at ~/Documents/kimi/workspace/streamdiffusion-mac/python)

Usage:
    python quilt_diffusion_worker.py --prompt "ukiyo-e style" --render-size 512
"""
import os
import sys
import struct
import signal
import argparse
import threading
import time

import numpy as np

_SD_MAC_PYTHON = os.environ.get(
    "SD_MAC_PYTHON",
    os.path.expanduser("~/Documents/kimi/workspace/streamdiffusion-mac/python"),
)
sys.path.insert(0, _SD_MAC_PYTHON)

_DEFAULT_MODELS = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "models")

_PROMPT_SENTINEL = 0xFFFFFFFF
_SEED_SENTINEL = 0xFFFFFFFD


def read_exact(n):
    data = b""
    while len(data) < n:
        chunk = sys.stdin.buffer.read(n - len(data))
        if not chunk:
            return None
        data += chunk
    return data


def write_view_frame(view_index, frame_rgb):
    h, w = frame_rgb.shape[:2]
    rgba = np.empty((h, w, 4), dtype=np.uint8)
    rgba[:, :, :3] = frame_rgb
    rgba[:, :, 3] = 255
    sys.stdout.buffer.write(struct.pack("<III", view_index, w, h))
    sys.stdout.buffer.write(rgba.tobytes())
    sys.stdout.buffer.flush()


def main():
    ap = argparse.ArgumentParser(description="Quilt diffusion worker")
    ap.add_argument("--prompt", type=str,
                    default="vaporwave ukiyo-e woodblock print style, neon pastel city, masterpiece")
    ap.add_argument("--model", type=str, default="sdxs")
    ap.add_argument("--render-size", type=int, default=512, choices=[320, 384, 512, 768])
    ap.add_argument("--strength", type=float, default=0.45)
    ap.add_argument("--feedback", type=float, default=0.15,
                    help="per-view latent temporal feedback (0 disables)")
    ap.add_argument("--seed", type=int, default=42)
    ap.add_argument("--coreml-dir", type=str, default=_DEFAULT_MODELS)
    ap.add_argument("--worker-id", type=int, default=0)
    ap.add_argument("--compute-units", type=str, default="all", choices=["all", "cpu_and_gpu"],
                    help="CoreML compute units; 'all' lets UNet run on ANE, freeing the GPU")
    ap.add_argument("--batch", type=int, default=1,
                    help="batched UNet: one call processes N views (needs unet_*_bN.mlpackage)")
    args = ap.parse_args()

    signal.signal(signal.SIGINT, lambda *_: os._exit(0))
    signal.signal(signal.SIGTERM, lambda *_: os._exit(0))

    if "distutils" not in sys.modules:
        import setuptools
        sys.modules["distutils"] = setuptools._distutils

    if args.compute_units == "all":
        # ANE offload: Python-side CoreML on ANE is numerically identical to
        # GPU here (A/B verified pixel-equal outputs). All models -> ALL frees
        # the GPU for the Metal render loop.
        import coremltools as _ct
        _orig_mlmodel = _ct.models.MLModel

        class _PatchedMLModel(_orig_mlmodel):
            def __init__(self, *a, **kw):
                kw["compute_units"] = _ct.ComputeUnit.ALL
                super().__init__(*a, **kw)

        _ct.models.MLModel = _PatchedMLModel

    from pipelines.coreml import Pipeline
    from configs import MODEL_CONFIGS

    # model_configs.json only has unet prefixes for 512/768; inject an entry for
    # other render sizes when the matching converted UNet exists in coreml-dir.
    model_name = args.model
    if args.render_size != 512:
        alt = f"sdxs-{args.render_size}"
        prefix = f"unet_sdxs_{args.render_size}"
        if os.path.exists(os.path.join(args.coreml_dir, prefix + ".mlpackage")):
            MODEL_CONFIGS[alt] = {**MODEL_CONFIGS["sdxs"], "unet_prefix": prefix,
                                  "render_size": args.render_size}
            model_name = alt
            print(f"[worker {args.worker_id}] using injected config {alt}", file=sys.stderr)

    # Pipeline init prints progress to fd 1 — redirect stdout to stderr during
    # init so the protocol channel stays clean.
    real_stdout = os.dup(1)
    os.dup2(2, 1)
    try:
        pipeline = Pipeline(
            model_name=model_name,
            render_size=args.render_size,
            output_size=args.render_size,
            prompt=args.prompt,
            strength=args.strength,
            prompts=None,
            latent_feedback=args.feedback,
            coreml_dir=args.coreml_dir,
            seed=args.seed,
        )
    finally:
        sys.stdout.flush()
        os.dup2(real_stdout, 1)
        os.close(real_stdout)

    # per-view temporal feedback buffers (view_index -> latent)
    prev_by_view = {}

    import cv2 as _cv2

    _DEPTH_NOISE_MIN = 0.25   # near floor: keep some style even on closest hits

    def depth_to_mask(depth_frame):
        """u8 depth (0=near) -> fp16 latent-space noise mask (1, 1, L, L)."""
        size = pipeline.render_size
        lat = pipeline.latent_size
        d = depth_frame.astype(np.float32) / 255.0
        if d.shape[0] != size:
            d = _cv2.resize(d, (size, size), interpolation=_cv2.INTER_AREA)
        m = _cv2.resize(d, (lat, lat), interpolation=_cv2.INTER_AREA)
        m = _cv2.GaussianBlur(m, (5, 5), 0)   # no seams at mask boundaries
        m = _DEPTH_NOISE_MIN + (1.0 - _DEPTH_NOISE_MIN) * m
        return m.astype(np.float16)[None, None]

    # Optional batched UNet (one ANE/GPU call stylizes several views).
    unet_batched = None
    if args.batch > 1:
        import coremltools as ct
        bpath = os.path.join(args.coreml_dir, f"unet_sdxs_{args.render_size}_b{args.batch}.mlpackage")
        cu = ct.ComputeUnit.ALL if args.compute_units == "all" else ct.ComputeUnit.CPU_AND_GPU
        unet_batched = ct.models.MLModel(bpath, compute_units=cu)
        print(f"[worker {args.worker_id}] batched UNet: {bpath}", file=sys.stderr, flush=True)

    def process_batch(frames):
        """frames: list of (view_index, rgb ndarray, depth ndarray). Batched UNet path."""
        import cv2
        size = pipeline.render_size
        latents = []
        cleans = []
        for view, frame, depth_frame in frames:
            h, w = frame.shape[:2]
            if w > h:
                off = (w - h) // 2
                frame = frame[:, off:off + h]
            elif h > w:
                off = (h - w) // 2
                frame = frame[off:off + w, :]
            resized = cv2.resize(frame, (size, size))
            img = pipeline._norm_lut[resized].transpose(2, 0, 1)[np.newaxis]
            enc = pipeline.vae_encoder.predict({"image": img})
            clean = np.array(enc["latent"]).astype(np.float16)
            prev = prev_by_view.get(view)
            if prev is not None and pipeline.latent_feedback > 0:
                fb = np.float16(pipeline.latent_feedback)
                clean = (1.0 - fb) * clean + fb * prev
            noisy = pipeline._sqrt_a * clean + pipeline._sqrt_1ma * pipeline._fixed_noise
            latents.append(noisy)
            cleans.append(clean)
        B = len(latents)
        lat = np.concatenate(latents, axis=0)
        tbuf = np.full((B,), pipeline._t_buf[0], dtype=np.float16)
        embeds = np.concatenate([pipeline._prompt_embeds] * B, axis=0)
        u = unet_batched.predict({"sample": lat, "timestep": tbuf,
                                  "encoder_hidden_states": embeds})
        npred = np.array(u["noise_pred"]).astype(np.float16)
        denoised = (lat - pipeline._sqrt_1ma * npred) / pipeline._sqrt_a
        for i, (view, _, depth_frame) in enumerate(frames):
            one = denoised[i:i + 1]
            one = depth_to_mask(depth_frame) * one + (np.float16(1.0) - depth_to_mask(depth_frame)) * cleans[i]
            prev_by_view[view] = one.copy()
            dec = pipeline.vae_decoder.predict({"latent": one})
            r = np.array(dec["image"]).astype(np.float32).squeeze(0).transpose(1, 2, 0)
            r = ((r + 1.0) * 127.5).clip(0, 255).astype(np.uint8)
            write_view_frame(view, r)

    print(f"[worker {args.worker_id}] ready pid={os.getpid()}", file=sys.stderr, flush=True)
    sys.stdout.buffer.write(struct.pack("<III", 0xFFFFFFFE, os.getpid(),
                                        threading.current_thread().ident & 0xFFFFFFFF))
    sys.stdout.buffer.flush()

    import select

    def read_frame_blocking():
        header = read_exact(12)
        if header is None:
            return None
        view_index, width, height = struct.unpack("<III", header)
        return ("pkt", view_index, width, height)

    while True:
        first = read_frame_blocking()
        if first is None:
            break
        _, view_index, width, height = first

        if view_index == _PROMPT_SENTINEL:
            prompt = read_exact(width).decode("utf-8")
            pipeline.set_prompt(prompt)
            print(f"[worker {args.worker_id}] prompt: {prompt}", file=sys.stderr, flush=True)
            continue
        if view_index == _SEED_SENTINEL:
            pipeline.set_seed(width)
            prev_by_view.clear()
            print(f"[worker {args.worker_id}] seed: {width}", file=sys.stderr, flush=True)
            continue

        pixels = read_exact(width * height * 3)
        if pixels is None:
            break
        depth_bytes = read_exact(width * height)
        if depth_bytes is None:
            break
        frame = np.frombuffer(pixels, dtype=np.uint8).reshape(height, width, 3)
        depth_frame = np.frombuffer(depth_bytes, dtype=np.uint8).reshape(height, width)

        if unet_batched is None:
            # single-view path with per-view feedback swap + depth mask
            pipeline._prev_denoised = prev_by_view.get(view_index)
            pipeline.depth_mask = depth_to_mask(depth_frame)
            result = pipeline.process_frame_rgb(frame)
            prev_by_view[view_index] = pipeline._prev_denoised
            write_view_frame(view_index, result)
            continue

        # batched path: gather more pending frames (non-blocking, short window)
        batch = [(view_index, frame, depth_frame)]
        deadline = time.time() + 0.012
        while len(batch) < args.batch:
            remaining = deadline - time.time()
            if remaining <= 0:
                break
            r, _, _ = select.select([sys.stdin], [], [], remaining)
            if not r:
                break
            nxt = read_frame_blocking()
            if nxt is None:
                break
            _, v2, w2, h2 = nxt
            if v2 >= 0xFFFFFFFC:
                # control packet mid-batch: handle minimally (prompt/seed)
                if v2 == _PROMPT_SENTINEL:
                    pipeline.set_prompt(read_exact(w2).decode("utf-8"))
                elif v2 == _SEED_SENTINEL:
                    pipeline.set_seed(w2)
                    prev_by_view.clear()
                continue
            px2 = read_exact(w2 * h2 * 3)
            if px2 is None:
                break
            db2 = read_exact(w2 * h2)
            if db2 is None:
                break
            batch.append((v2, np.frombuffer(px2, dtype=np.uint8).reshape(h2, w2, 3),
                          np.frombuffer(db2, dtype=np.uint8).reshape(h2, w2)))
        process_batch(batch)
        frame = np.frombuffer(pixels, dtype=np.uint8).reshape(height, width, 3)

        # swap in this view's feedback buffer
        pipeline._prev_denoised = prev_by_view.get(view_index)
        result = pipeline.process_frame_rgb(frame)
        prev_by_view[view_index] = pipeline._prev_denoised

        write_view_frame(view_index, result)


if __name__ == "__main__":
    main()
