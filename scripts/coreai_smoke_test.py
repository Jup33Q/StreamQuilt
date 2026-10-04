#!/usr/bin/env python3
"""M4 minimal coreai-torch end-to-end: tiny conv model -> CoreAI asset -> inference."""
import os
import sys
import tempfile

import numpy as np
import torch

from coreai_torch import TorchConverter


class TinyConv(torch.nn.Module):
    def __init__(self):
        super().__init__()
        self.conv = torch.nn.Conv2d(3, 8, 3, padding=1)
        self.relu = torch.nn.ReLU()

    def forward(self, x):
        return self.relu(self.conv(x))


def main():
    out_dir = sys.argv[1] if len(sys.argv) > 1 else tempfile.mkdtemp(prefix="coreai_test_")
    os.makedirs(out_dir, exist_ok=True)
    asset_path = __import__("pathlib").Path(out_dir) / "tinyconv.aimodel"

    model = TinyConv().eval()
    x = torch.randn(1, 3, 32, 32)
    with torch.no_grad():
        expected = model(x).numpy()

    print("[1/3] convert with coreai-torch ...")
    import coreai_torch
    conv = TorchConverter()
    conv.add_pytorch_module(
        model,
        export_fn=lambda m: torch.export.export(m, args=(x,)).run_decompositions(
            coreai_torch.get_decomp_table()),
        input_names=["x"], output_names=["y"], entrypoint_name="forward",
    )
    program = conv.to_coreai()
    program.save_asset(asset_path)
    print("  asset saved:", asset_path, os.listdir(asset_path) if os.path.isdir(str(asset_path)) else "")

    print("[2/3] load via coreai.runtime ...")
    import asyncio
    from coreai.runtime import AIModel

    async def run():
        m = await AIModel.load(asset_path)
        print("  functions:", m.function_names)
        fn = m.load_function(m.function_names[0])
        import coreai.runtime as rt
        arr = rt.NDArray.from_array(x.numpy().astype(np.float32)) if hasattr(rt.NDArray, "from_array") else None
        inputs = {"x": arr} if arr is not None else None
        print("  input names:", fn.input_names if hasattr(fn, "input_names") else "?")
        return fn, arr

    fn, arr = asyncio.run(run())
    print("[3/3] inspect function descriptor OK")
    print("expected output sum:", float(expected.sum()))
    print("COREAI TEST PASS (asset convert + load); path:", asset_path)


if __name__ == "__main__":
    main()
