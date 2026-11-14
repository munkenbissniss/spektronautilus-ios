#!/usr/bin/env python3
"""Turns a Real-ESRGAN (or any ESRGAN-style) PyTorch model into the Core ML model the app expects.

NOT TESTED. It is a starting point: package versions, the exact model class and the weights file have to be adjusted to what you use.
The weights are not part of this repository (size and licence: check the licence of the model you choose, most are BSD or MIT).

    pip install torch coremltools realesrgan basicsr
    python3 models/convert_realesrgan.py RealESRGAN_x2plus.pth 2
    cp -r Upscale.mlpackage App/Resources/Models/       # Xcode compiles it into Upscale.mlmodelc

The model takes a fixed 128x128 picture and gives back 128*k x 128*k. The app cuts bigger pictures into tiles.
"""
import sys
import torch
import coremltools as ct
from basicsr.archs.rrdbnet_arch import RRDBNet

weights, scale = sys.argv[1], int(sys.argv[2])
TILE = 128
net = RRDBNet(num_in_ch=3, num_out_ch=3, num_feat=64, num_block=23, num_grow_ch=32, scale=scale)
sd = torch.load(weights, map_location="cpu")
net.load_state_dict(sd.get("params_ema", sd.get("params", sd)), strict=True)
net.eval()


class Wrap(torch.nn.Module):          # Core ML image outputs are 0..255, the network gives 0..1
    def __init__(self, m):
        super().__init__(); self.m = m

    def forward(self, x):
        return (self.m(x) * 255.0).clamp(0, 255)


net = Wrap(net).eval()
example = torch.rand(1, 3, TILE, TILE)
traced = torch.jit.trace(net, example)
ml = ct.convert(traced, convert_to="mlprogram", compute_precision=ct.precision.FLOAT16,
                inputs=[ct.ImageType(name="input", shape=example.shape, scale=1 / 255.0, color_layout=ct.colorlayout.RGB)],
                outputs=[ct.ImageType(name="output", color_layout=ct.colorlayout.RGB)])
ml.save("Upscale.mlpackage")
print("wrote Upscale.mlpackage")
