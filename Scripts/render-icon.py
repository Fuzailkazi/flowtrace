#!/usr/bin/env python3
"""Draw the FlowTrace app icon master at 1024x1024 with real transparency.

Drawn rather than rasterised from SVG because qlmanage flattens alpha, and a
macOS icon needs transparent corners. The plate is a superellipse (Apple's
squircle, continuous curvature) rather than a rounded rectangle -- a rounded
rect is the single most common tell of a non-native Mac icon.
"""
import math
from PIL import Image, ImageDraw

S = 4                      # supersample factor, downscaled at the end
N = 1024 * S

PAPER = (247, 245, 238, 255)   # #F7F5EE  ground
INK   = (42, 37, 32, 255)      # #2A2520  still alive
RULE  = (207, 199, 180, 255)   # #CFC7B4  stopped, and nobody noticed


def superellipse(cx, cy, a, n=5.0, steps=2048):
    """Apple-style squircle: |x/a|^n + |y/a|^n = 1."""
    pts = []
    for i in range(steps):
        t = 2 * math.pi * i / steps
        ct, st = math.cos(t), math.sin(t)
        x = a * math.copysign(abs(ct) ** (2.0 / n), ct)
        y = a * math.copysign(abs(st) ** (2.0 / n), st)
        pts.append((cx + x, cy + y))
    return pts


def bar(d, x1, x2, y, w):
    """A stroke with round caps == a fully-rounded rectangle."""
    r = w / 2
    d.rounded_rectangle([x1 - r, y - r, x2 + r, y + r], radius=r, fill=INK)


def ring(d, cx, cy, r, w):
    d.ellipse([cx - r - w / 2, cy - r - w / 2, cx + r + w / 2, cy + r + w / 2], fill=RULE)
    d.ellipse([cx - r + w / 2, cy - r + w / 2, cx + r - w / 2, cy + r - w / 2],
              fill=(0, 0, 0, 0))


img = Image.new("RGBA", (N, N), (0, 0, 0, 0))
d = ImageDraw.Draw(img)

# The plate: 824 of 1024, centred -- Apple's content area for a macOS icon.
d.polygon(superellipse(512 * S, 512 * S, 412 * S), fill=PAPER)

# Three places. The first two are running; the last one stopped.
bar(d, 304 * S, 628 * S, 362 * S, 64 * S)
bar(d, 304 * S, 720 * S, 512 * S, 64 * S)
bar(d, 304 * S, 450 * S, 662 * S, 64 * S)

# ...and trails off.
ring(d, 540 * S, 662 * S, 32 * S, 20 * S)
ring(d, 628 * S, 662 * S, 22 * S, 15 * S)

img.resize((1024, 1024), Image.LANCZOS).save("AppIcon-1024.png")
print("wrote AppIcon-1024.png (1024x1024, RGBA, transparent corners)")
