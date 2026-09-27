#!/usr/bin/env python3
# Per-frame pixel bounding-box of a colored icon (e.g. the Firefox flame)
# inside a search window, for hover-inflate verification.
#
# Pure PIL (no numpy on this host): threshold the H/S/V channels with
# point(), AND them via ImageChops.multiply, take getbbox() — all C-speed,
# so a full-rate video extraction measures in seconds.
#
# The measurement is the authority (single-frame raster swaps are invisible
# to casual viewing — S54a). A frame's bbox that differs from its neighbors'
# by more than rounding noise marks a wrong-size texture swap; a bbox frozen
# at the idle size through a hover marks a raster that never arrived.
#
# Usage:
#   measure_icon_bbox.py <frame_dir> --win X0,Y0,X1,Y1 --hue LO,HI --sat N --val N
#     One line per frame (sorted names): name w h cx cy area
#   Add --scan to only LIST candidate blobs (area-sorted, top 12) per frame
#   with --win covering the whole frame — used to locate the target before
#   committing to a window. Hue/sat/val are PIL HSV 0..255.
#   Add --video <fps> to append a seconds column (t = (n-1)/fps).
import sys, os, argparse
from PIL import Image, ImageChops

ap = argparse.ArgumentParser()
ap.add_argument("frame_dir")
ap.add_argument("--win", default=None, help="X0,Y0,X1,Y1 search window")
ap.add_argument("--hue", default="6,40", help="hue window 0..255")
ap.add_argument("--sat", type=int, default=90, help="min saturation 0..255")
ap.add_argument("--val", type=int, default=90, help="min value 0..255")
ap.add_argument("--scan", action="store_true", help="list candidate blobs")
ap.add_argument("--largest", action="store_true",
                help="per-frame bbox of the LARGEST blob only (robust when "
                     "other small matching blobs share the window)")
ap.add_argument("--start", type=int, default=0, help="skip first N frames")
ap.add_argument("--limit", type=int, default=0, help="process at most N frames (0 = all)")
ap.add_argument("--video", type=float, default=0, help="fps for t column")
args = ap.parse_args()

h0, h1 = (int(v) for v in args.hue.split(","))
win = None
if args.win:
    win = tuple(int(v) for v in args.win.split(","))


def mask_bbox(im):
    hsv = im.convert("HSV")
    h, s, v = hsv.split()
    mh = h.point(lambda p: 255 if h0 <= p <= h1 else 0)
    ms = s.point(lambda p: 255 if p >= args.sat else 0)
    mv = v.point(lambda p: 255 if p >= args.val else 0)
    m = ImageChops.multiply(ImageChops.multiply(mh, ms), mv)
    return m


def blobs(m, min_area=40):
    # connected components via flood fill on a binary mask (small windows
    # only — this is the slow path used by --scan)
    px = m.load()
    w, h = m.size
    seen = set()
    out = []
    for y in range(h):
        for x in range(w):
            if px[x, y] and (x, y) not in seen:
                stack = [(x, y)]
                seen.add((x, y))
                n = 0
                x0 = x1 = x
                y0 = y1 = y
                while stack:
                    cx, cy = stack.pop()
                    n += 1
                    x0 = min(x0, cx); x1 = max(x1, cx)
                    y0 = min(y0, cy); y1 = max(y1, cy)
                    for nx, ny in ((cx+1, cy), (cx-1, cy), (cx, cy+1), (cx, cy-1)):
                        if 0 <= nx < w and 0 <= ny < h and px[nx, ny] and (nx, ny) not in seen:
                            seen.add((nx, ny))
                            stack.append((nx, ny))
                if n >= min_area:
                    out.append((n, x0, y0, x1, y1))
    out.sort(reverse=True)
    return out[:12]


files = sorted(f for f in os.listdir(args.frame_dir) if f.endswith(".png"))
if args.start:
    files = files[args.start:]
if args.limit:
    files = files[:args.limit]
for f in files:
    im = Image.open(os.path.join(args.frame_dir, f))
    if win:
        im = im.crop(win)
    m = mask_bbox(im)
    if args.scan:
        for n, x0, y0, x1, y1 in blobs(m):
            off = (win[0], win[1]) if win else (0, 0)
            print(f"{f} area={n} bbox={x0+off[0]},{y0+off[1]},{x1+off[0]},{y1+off[1]} "
                  f"w={x1-x0+1} h={y1-y0+1}")
    elif args.largest:
        t = ""
        if args.video:
            t = f"t={(int(f[1:5]) - 1) / args.video:7.3f} "
        bb = blobs(m, min_area=100)
        if bb:
            n, x0, y0, x1, y1 = bb[0]
            off = (win[0], win[1]) if win else (0, 0)
            print(f"{f} {t}w={x1-x0+1} h={y1-y0+1} cx={(x0+x1)/2+off[0]:.0f} "
                  f"cy={(y0+y1)/2+off[1]:.0f} area={n}")
        else:
            print(f"{f} {t}w=0 h=0 (no blob)")
    else:
        b = m.getbbox()
        if b:
            w = b[2] - b[0]
            h = b[3] - b[1]
            area = sum(1 for p in m.getdata() if p)
            cx = b[0] + w / 2 + (win[0] if win else 0)
            cy = b[1] + h / 2 + (win[1] if win else 0)
            t = ""
            if args.video:
                t = f"t={(int(f[1:5]) - 1) / args.video:7.3f} "
            print(f"{f} {t}w={w} h={h} cx={cx:.0f} cy={cy:.0f} area={area}")
        else:
            print(f"{f} w=0 h=0 (no mask pixels)")
