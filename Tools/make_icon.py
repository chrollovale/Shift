#!/usr/bin/env python3
"""
Generates Shift's app icon: two opposing arrows on an ink-black squircle.

    python3 Tools/make_icon.py

Writes Resources/AppIcon.iconset/*.png, Resources/AppIcon.icns and
Resources/AppIcon-1024.png. Requires Pillow.
"""
import math
import os

from PIL import Image, ImageChops, ImageDraw, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.normpath(os.path.join(HERE, "..", "Resources"))

SS = 4                      # supersampling factor
BASE = 1024
N = BASE * SS

INK_TOP = (50, 48, 44)
INK_BOTTOM = (22, 21, 19)
CREAM = (246, 239, 222)
ORANGE = (242, 84, 45)


def s(v):
    """Scale a 1024-space coordinate onto the supersampled canvas."""
    return v * SS


def squircle(size, inset, n=5.0):
    """Superellipse mask, close to Apple's continuous-corner icon shape."""
    c = size / 2
    r = size / 2 - inset
    pts = []
    for i in range(3000):
        t = 2 * math.pi * i / 3000
        ct, st = math.cos(t), math.sin(t)
        pts.append((c + r * math.copysign(abs(ct) ** (2 / n), ct),
                    c + r * math.copysign(abs(st) ** (2 / n), st)))
    m = Image.new("L", (size, size), 0)
    ImageDraw.Draw(m).polygon(pts, fill=255)
    return m


def vertical_gradient(size, top, bottom):
    strip = Image.new("RGB", (1, size))
    px = strip.load()
    for y in range(size):
        k = y / (size - 1)
        px[0, y] = tuple(round(top[i] + (bottom[i] - top[i]) * k) for i in range(3))
    return strip.resize((size, size))


def stroke_path(draw, points, width, fill):
    """Polyline with round caps and round joins."""
    r = width / 2
    for a, b in zip(points, points[1:]):
        draw.line([a, b], fill=fill, width=round(width))
    for x, y in points:
        draw.ellipse([x - r, y - r, x + r, y + r], fill=fill)


def arrow_points(x_tail, x_tip, y, head, direction):
    """Points for one horizontal arrow drawn as a single polyline pair."""
    back = -head if direction > 0 else head
    shaft = [(s(x_tail), s(y)), (s(x_tip), s(y))]
    chevron = [(s(x_tip + back), s(y - head)), (s(x_tip), s(y)), (s(x_tip + back), s(y + head))]
    return shaft, chevron


def draw_arrow(layer_draw, x_tail, x_tip, y, head, width, fill, direction):
    shaft, chevron = arrow_points(x_tail, x_tip, y, head, direction)
    stroke_path(layer_draw, shaft, s(width), fill)
    stroke_path(layer_draw, chevron, s(width), fill)


def main():
    body = squircle(N, s(100))                      # 824px body inside 1024 canvas

    # --- drop shadow -------------------------------------------------------
    shadow = body.filter(ImageFilter.GaussianBlur(s(16)))
    shadow = ImageChops.offset(shadow, 0, s(12))
    shadow = shadow.point(lambda v: int(v * 0.38))
    canvas = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    canvas.paste(Image.new("RGBA", (N, N), (0, 0, 0, 255)), (0, 0), shadow)

    # --- ink body with soft vertical gradient -----------------------------
    gradient = vertical_gradient(N, INK_TOP, INK_BOTTOM).convert("RGBA")
    canvas.paste(gradient, (0, 0), body)

    # --- fine top-edge highlight ------------------------------------------
    inner = squircle(N, s(100) + s(5))
    rim = ImageChops.subtract(body, inner)
    fade = Image.new("L", (1, N))
    fpx = fade.load()
    for y in range(N):
        k = max(0.0, 1 - (y - s(100)) / s(420))
        fpx[0, y] = int(255 * 0.30 * k)
    fade = fade.resize((N, N))
    rim = ImageChops.multiply(rim, fade)
    canvas.paste(Image.new("RGBA", (N, N), (255, 255, 255, 255)), (0, 0), rim)

    # --- the mark: two arrows passing each other ---------------------------
    marks = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    md = ImageDraw.Draw(marks)
    W = 66        # stroke width
    H = 98        # arrowhead arm length
    draw_arrow(md, 262, 722, 408, H, W, CREAM + (255,), +1)     # top    ->
    draw_arrow(md, 762, 302, 616, H, W, ORANGE + (255,), -1)    # bottom <-

    mark_shadow = marks.filter(ImageFilter.GaussianBlur(s(10)))
    mark_shadow = ImageChops.offset(mark_shadow, 0, s(8))
    r, g, b, a = mark_shadow.split()
    mark_shadow = Image.merge("RGBA", (r.point(lambda v: 0), g.point(lambda v: 0),
                                       b.point(lambda v: 0), a.point(lambda v: int(v * 0.45))))
    canvas = Image.alpha_composite(canvas, mark_shadow)
    canvas = Image.alpha_composite(canvas, marks)

    icon = canvas.resize((BASE, BASE), Image.LANCZOS)

    # --- write files --------------------------------------------------------
    os.makedirs(OUT, exist_ok=True)
    iconset = os.path.join(OUT, "AppIcon.iconset")
    os.makedirs(iconset, exist_ok=True)
    sizes = {
        "icon_16x16.png": 16, "icon_16x16@2x.png": 32,
        "icon_32x32.png": 32, "icon_32x32@2x.png": 64,
        "icon_128x128.png": 128, "icon_128x128@2x.png": 256,
        "icon_256x256.png": 256, "icon_256x256@2x.png": 512,
        "icon_512x512.png": 512, "icon_512x512@2x.png": 1024,
    }
    for name, px in sizes.items():
        icon.resize((px, px), Image.LANCZOS).save(os.path.join(iconset, name))

    icon.save(os.path.join(OUT, "AppIcon-1024.png"))
    icon.save(
        os.path.join(OUT, "AppIcon.icns"),
        format="ICNS",
        sizes=[(16, 16), (32, 32), (64, 64), (128, 128), (256, 256), (512, 512), (1024, 1024)],
    )
    print("wrote", OUT)


if __name__ == "__main__":
    main()
