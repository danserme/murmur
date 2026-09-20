#!/usr/bin/env python3
"""Finder DMG backdrop at 1× window size (620×380). Finder does not honor @2x backgrounds."""

from __future__ import annotations

import math
import subprocess
import tempfile
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[1]
WINDOW = (620, 400)
DRAW_SCALE = 4
LEFT_ICON = (155, 185)
RIGHT_ICON = (465, 185)
ICON_SIZE = 128

CANVAS = (243, 241, 236)
INK = (28, 27, 25)
MUTED = (138, 134, 128)
BRAND = (21, 0, 206)


def load_font(size: int) -> ImageFont.FreeTypeFont:
    for path in (
        "/System/Library/Fonts/SFNS.ttf",
        "/System/Library/Fonts/HelveticaNeue.ttc",
        "/System/Library/Fonts/Supplemental/Arial.ttf",
    ):
        if Path(path).exists():
            try:
                return ImageFont.truetype(path, size=size)
            except OSError:
                continue
    return ImageFont.load_default()


def lerp(a: float, b: float, t: float) -> float:
    return a + (b - a) * t


def bezier(t: float, pts: list[tuple[float, float]]) -> tuple[float, float]:
    p0, p1, p2, p3 = pts
    u = 1 - t
    return (
        u**3 * p0[0] + 3 * u**2 * t * p1[0] + 3 * u * t**2 * p2[0] + t**3 * p3[0],
        u**3 * p0[1] + 3 * u**2 * t * p1[1] + 3 * u * t**2 * p2[1] + t**3 * p3[1],
    )


def bezier_tangent(t: float, pts: list[tuple[float, float]]) -> tuple[float, float]:
    p0, p1, p2, p3 = pts
    u = 1 - t
    return (
        3 * u * u * (p1[0] - p0[0]) + 6 * u * t * (p2[0] - p1[0]) + 3 * t * t * (p3[0] - p2[0]),
        3 * u * u * (p1[1] - p0[1]) + 6 * u * t * (p2[1] - p1[1]) + 3 * t * t * (p3[1] - p2[1]),
    )


def round_line(draw, a, b, *, color, width: float) -> None:
    draw.line([a, b], fill=color, width=int(round(width)))
    r = width / 2
    for point in (a, b):
        draw.ellipse((point[0] - r, point[1] - r, point[0] + r, point[1] + r), fill=color)


def dashed_curve(draw, pts, *, color, width: float, dash: float, gap: float):
    samples = 400
    points = [bezier(i / samples, pts) for i in range(samples + 1)]
    drawing = True
    used = 0.0
    last = points[0]
    for point in points[1:]:
        length = math.hypot(point[0] - last[0], point[1] - last[1])
        if drawing:
            round_line(draw, last, point, color=color, width=width)
        used += length
        last = point
        if used >= (dash if drawing else gap):
            drawing = not drawing
            used = 0.0
    return points[-2], bezier_tangent(0.985, pts)


def arrow_head(draw, tip, tangent, *, color, size: float) -> None:
    angle = math.atan2(tangent[1], tangent[0])
    left = (
        tip[0] + size * math.cos(angle + math.radians(148)),
        tip[1] + size * math.sin(angle + math.radians(148)),
    )
    right = (
        tip[0] + size * math.cos(angle - math.radians(148)),
        tip[1] + size * math.sin(angle - math.radians(148)),
    )
    draw.polygon([tip, left, right], fill=color)


def wordmark_image(height: int) -> Image.Image:
    svg = ROOT / "murmur/Assets.xcassets/AppLogo.imageset/AppLogo.svg"
    with tempfile.TemporaryDirectory() as tmp:
        out = Path(tmp) / "wordmark.png"
        subprocess.run(["rsvg-convert", "-h", str(height), str(svg), "-o", str(out)], check=True)
        return Image.open(out).convert("RGBA")


def render(path: Path) -> Image.Image:
    s = DRAW_SCALE
    w, h = WINDOW[0] * s, WINDOW[1] * s
    img = Image.new("RGBA", (w, h), (*CANVAS, 255))

    mark = wordmark_image(int(20 * s))
    img.alpha_composite(mark, ((w - mark.width) // 2, int(22 * s)))

    caption = ImageDraw.Draw(img)
    caption.text(
        (w / 2, 72 * s),
        "Drag murmur to Applications",
        font=load_font(int(13 * s)),
        fill=MUTED,
        anchor="mm",
    )
    caption.text(
        (w / 2, 372 * s),
        "After installing, delete this disk image",
        font=load_font(int(11 * s)),
        fill=MUTED,
        anchor="mm",
    )

    overlay = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    draw = ImageDraw.Draw(overlay)
    inset = ICON_SIZE / 2 + 22
    start = ((LEFT_ICON[0] + inset) * s, LEFT_ICON[1] * s)
    end = ((RIGHT_ICON[0] - inset) * s, RIGHT_ICON[1] * s)
    peak = 36 * s
    pts = [
        start,
        (lerp(start[0], end[0], 0.34), start[1] - peak),
        (lerp(start[0], end[0], 0.66), end[1] - peak),
        end,
    ]
    tip, tangent = dashed_curve(
        draw, pts, color=(*BRAND, 170), width=3.0 * s, dash=12 * s, gap=9 * s
    )
    arrow_head(draw, tip, tangent, color=(*BRAND, 190), size=11 * s)
    img = Image.alpha_composite(img, overlay)

    rgb = img.resize(WINDOW, Image.Resampling.LANCZOS).convert("RGB")
    path.parent.mkdir(parents=True, exist_ok=True)
    rgb.save(path, "PNG", optimize=True)
    return rgb


if __name__ == "__main__":
    render(Path(__file__).with_name("dmg-background.png"))
