#!/usr/bin/env python3
"""Export prompt embedding + scheduler scalars for the Swift CoreML spike.

Produces in the output dir:
  prompt_embeds.npy   float16 (1, 77, 1024)
  sched.json          {"timestep": t, "sqrt_a": ..., "sqrt_1ma": ...}
"""
import json
import os
import sys

import numpy as np

SD_MAC_PYTHON = os.path.expanduser("~/Documents/kimi/workspace/streamdiffusion-mac/python")
sys.path.insert(0, SD_MAC_PYTHON)

if "distutils" not in sys.modules:
    import setuptools
    sys.modules["distutils"] = setuptools._distutils


def main():
    out_dir = sys.argv[1] if len(sys.argv) > 1 else "/tmp/lkg_spike"
    prompt = sys.argv[2] if len(sys.argv) > 2 else \
        "vaporwave ukiyo-e woodblock print style, neon pastel city, masterpiece"
    strength = float(sys.argv[3]) if len(sys.argv) > 3 else 0.45
    os.makedirs(out_dir, exist_ok=True)

    from pipelines.coreml import Pipeline
    from configs import MODEL_CONFIGS

    render_size = 384
    alt = f"sdxs-{render_size}"
    prefix = f"unet_sdxs_{render_size}"
    models_dir = os.path.expanduser("~/Desktop/StreamQuilt/models")
    if os.path.exists(os.path.join(models_dir, prefix + ".mlpackage")):
        MODEL_CONFIGS[alt] = {**MODEL_CONFIGS["sdxs"], "unet_prefix": prefix,
                              "render_size": render_size}

    pipe = Pipeline(model_name=alt, render_size=384, output_size=384,
                    prompt=prompt, strength=strength, prompts=None,
                    latent_feedback=0.0,
                    coreml_dir=models_dir,
                    seed=42)

    np.save(os.path.join(out_dir, "prompt_embeds.npy"), pipe._prompt_embeds)
    meta = {
        "timestep": float(pipe._t_buf[0]),
        "sqrt_a": float(pipe._sqrt_a),
        "sqrt_1ma": float(pipe._sqrt_1ma),
        "render_size": pipe.render_size,
        "latent_size": pipe.latent_size,
        "prompt": prompt,
    }
    with open(os.path.join(out_dir, "sched.json"), "w") as f:
        json.dump(meta, f, indent=1)
    # also export the fixed noise so Swift results match Python bit-closely
    np.save(os.path.join(out_dir, "fixed_noise.npy"), pipe._fixed_noise)
    print("exported to", out_dir, meta)


if __name__ == "__main__":
    main()
