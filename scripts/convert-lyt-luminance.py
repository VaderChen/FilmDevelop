#!/usr/bin/env python3
"""Build FilmDevelop's luminance-only LYT-Net Core ML resource.

Architecture and pretrained model: Alexandru Brateanu et al., MIT license.
https://github.com/albrateanu/LYT-Net
Use the pinned model/checkpoint hashes in PhotoStyleShared/DEEP_SHADOW_EXPOSURE.md.
This developer tool requires torch and coremltools; the app requires neither.
"""
import argparse
import hashlib
import importlib.util
from pathlib import Path
import numpy as np
import torch
import coremltools as ct

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--source", type=Path, required=True)
parser.add_argument("--checkpoint", type=Path, required=True)
parser.add_argument("--output", type=Path, required=True)
args = parser.parse_args()
model_path = args.source / "PyTorch/model.py"
for path, digest in [(model_path, "58730d4f6b134b15c3d7ac29cef93769d371a13ead5b9e01d058606ff79d88c9"),
                     (args.checkpoint, "19c15bbe5e4d961d7c27f26998c90c39ef81759af027ba1aba9f32d6fe98462d")]:
    if hashlib.sha256(path.read_bytes()).hexdigest() != digest:
        raise ValueError(f"Unexpected source/checkpoint: {path}")
spec = importlib.util.spec_from_file_location("lytmodel", model_path)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
base = m.LYT()
base.load_state_dict(torch.load(args.checkpoint, map_location="cpu", weights_only=True))
base.eval()

class LuminanceOnly(torch.nn.Module):
    def __init__(self, base):
        super().__init__()
        self.base = base

    def forward(self, y):
        b = self.base
        neutral = torch.full_like(y, 0.5)
        cb = b.denoiser_cb(neutral) + neutral
        cr = b.denoiser_cr(neutral) + neutral
        yp, cbp, crp = b.process_y(y), b.process_cb(cb), b.process_cr(cr)
        lum = yp + b.lum_up(b.lum_mhsa(b.lum_pool(yp)))
        ref = b.ref_conv(torch.cat([cbp, crp], 1))
        ref = b.msef(ref + 0.2 * b.lum_conv(lum)) + ref
        out = torch.sigmoid(b.final_adjustments(b.recombine(torch.cat([ref, lum], 1))))
        # Decode each predicted component before computing a physical linear Y.
        linear = torch.where(out <= 0.04045, out / 12.92,
                             torch.pow((out + 0.055) / 1.055, 2.4))
        return (linear[:, 0:1] * 0.21263900587151027
                + linear[:, 1:2] * 0.7151686787677559
                + linear[:, 2:3] * 0.07219231536073371)


net = LuminanceOnly(base).eval()
example = torch.ones(1, 1, 256, 384) * 0.08
with torch.no_grad():
    traced = torch.jit.trace(net, example)
model = ct.convert(
    traced,
    inputs=[ct.TensorType(name="luminance", shape=example.shape)],
    outputs=[ct.TensorType(name="enhancedLuminance", dtype=np.float32)],
    convert_to="mlprogram",
    minimum_deployment_target=ct.target.macOS13,
    compute_precision=ct.precision.FLOAT32,
)
model.author = "Alexandru Brateanu et al.; luminance-only Core ML adaptation for FilmDevelop"
model.short_description = ("LYT-Net luminance-only enhancement. Input is sRGB-encoded "
                           "luminance, neutral chroma; output is linear Y.")
model.license = (args.source / "LICENSE").read_text()
model.save(str(args.output))
print(f"Saved {args.output}")
