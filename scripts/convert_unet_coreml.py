#!/usr/bin/env python3
"""Convert a locally-cached diffusers UNet to CoreML (offline).

Adapted from streamdiffusion-mac/python/scripts/convert_models.py to work from a
local HF snapshot path (no Hub metadata call), for machines where
huggingface.co is unreachable.

Usage:
    python convert_unet_coreml.py \
        --snapshot ~/.cache/huggingface/hub/models--IDKiro--sdxs-512-0.9/snapshots/<hash> \
        --hidden-size 1024 --size 512 --output models/unet_sdxs_512.mlpackage
"""
import argparse
import gc
import os
import sys
import time

# Python 3.12 removed distutils; coremltools still imports it.
if "distutils" not in sys.modules:
    import setuptools
    sys.modules["distutils"] = setuptools._distutils

import numpy as np
import torch
import coremltools as ct


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--snapshot", required=True, help="local HF snapshot directory")
    ap.add_argument("--hidden-size", type=int, default=1024)
    ap.add_argument("--size", type=int, default=512)
    ap.add_argument("--batch", type=int, default=1,
                    help="UNet batch size; >1 lets one call stylize several views at once")
    ap.add_argument("--output", required=True)
    args = ap.parse_args()

    from diffusers import StableDiffusionPipeline

    print(f"Loading UNet from local snapshot: {args.snapshot}")
    try:
        pipe = StableDiffusionPipeline.from_pretrained(
            args.snapshot, torch_dtype=torch.float16, variant="fp16", local_files_only=True)
    except (ValueError, OSError):
        pipe = StableDiffusionPipeline.from_pretrained(
            args.snapshot, torch_dtype=torch.float16, local_files_only=True)
    unet = pipe.unet.eval().float().cpu()

    class UNetWrapper(torch.nn.Module):
        def __init__(self, unet):
            super().__init__()
            self.unet = unet

        def forward(self, sample, timestep, encoder_hidden_states):
            return self.unet(sample, timestep,
                             encoder_hidden_states=encoder_hidden_states,
                             return_dict=False)[0]

    wrapper = UNetWrapper(unet).eval()
    latent = args.size // 8
    B = args.batch
    sample = torch.randn(B, 4, latent, latent)
    timestep = torch.tensor([999.0] * B)
    hidden = torch.randn(B, 77, args.hidden_size)

    print(f"Tracing UNet at {args.size}x{args.size} batch={B} (latent {latent}x{latent})...")
    with torch.no_grad():
        traced = torch.jit.trace(wrapper, (sample, timestep, hidden))

    print("Converting to CoreML (may take several minutes)...")
    t0 = time.time()
    model = ct.convert(
        traced,
        inputs=[
            ct.TensorType(name="sample", shape=sample.shape, dtype=np.float16),
            ct.TensorType(name="timestep", shape=timestep.shape, dtype=np.float16),
            ct.TensorType(name="encoder_hidden_states", shape=hidden.shape, dtype=np.float16),
        ],
        outputs=[ct.TensorType(name="noise_pred", dtype=np.float16)],
        compute_units=ct.ComputeUnit.ALL,
        minimum_deployment_target=ct.target.macOS14,
        convert_to="mlprogram",
    )
    print(f"UNet converted in {time.time() - t0:.1f}s")
    os.makedirs(os.path.dirname(os.path.abspath(args.output)), exist_ok=True)
    model.save(args.output)
    print(f"Saved: {args.output}")

    del pipe, unet, wrapper, traced, model
    gc.collect()


if __name__ == "__main__":
    main()
