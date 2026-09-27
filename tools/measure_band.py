#!/usr/bin/env python3
# Measure the music popup's x-extent per frame: in the band y=392..418
# (just inside the frame's top edge, above the icons) background chat text
# is dark-on-white; where the popup covers, the band is uniformly light.
# A column counts as covered when its dark-pixel count in the band is <= 1.
# NOTE: the absolute left/right values carry a ~30px inward bias from the
# frame's rounded corners; the numbers are consistent ACROSS frames, so
# shifts/jumps are reliable even where absolute edges are biased.
# Usage: measure_band.py <frame_dir> <t0_seconds>   (frames named hNNN.png,
# t = t0 + (N-1)/20 — 20fps extraction)
from PIL import Image
import os, sys

d = sys.argv[1] if len(sys.argv) > 1 else "/tmp/afvid0/w1"
t0 = float(sys.argv[2]) if len(sys.argv) > 2 else 25.3
y0, y1 = 392, 418
files = sorted(os.listdir(d))
for f in files:
    if not f.endswith(".png"):
        continue
    im = Image.open(os.path.join(d, f)).convert("L")
    px = im.load()
    cols = []
    for x in range(800, 1800):
        dark = 0
        for y in range(y0, y1):
            if px[x, y] < 120:
                dark += 1
        cols.append(dark == 0)
    # longest run of covered columns
    best = (0, 0, 0)
    run = 0
    start = 0
    for i, c in enumerate(cols):
        if c:
            if run == 0:
                start = i
            run += 1
            if run > best[0]:
                best = (run, start, i)
        else:
            run = 0
    n = int(f[1:4])
    t = t0 + (n - 1) / 20.0
    x_start = 800 + best[1]
    x_end = 800 + best[2]
    print(f"{f} t={t:6.2f} covered={x_start}..{x_end} len={best[0]}")
