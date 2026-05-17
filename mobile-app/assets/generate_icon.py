"""
EchoLang app-icon generator.

Concept: a focal dot on the left with three concentric arcs rippling outward to
the right. Reads as "sound radiating" / "echo" while staying iconic at 29×29
in iOS Settings. The background is a deep-navy → teal gradient so the icon
feels education-adjacent (calm/trustworthy) without becoming generic tech-blue.

Outputs two assets:
  assets/icon.png             — 1024×1024 full icon (iOS App Store + master)
  assets/icon_foreground.png  — 1024×1024 transparent foreground for Android
                                 adaptive icon (background handled separately)
"""
from __future__ import annotations

from PIL import Image, ImageDraw

SIZE = 1024


def lerp(a: tuple[int, int, int], b: tuple[int, int, int], t: float) -> tuple[int, int, int]:
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))


def gradient_background() -> Image.Image:
    img = Image.new("RGB", (SIZE, SIZE))
    # Deep navy → teal, diagonal top-left to bottom-right.
    c0 = (15, 35, 64)      # #0F2340
    c1 = (45, 212, 191)    # #2DD4BF
    px = img.load()
    diag = (SIZE - 1) * 2
    for y in range(SIZE):
        for x in range(SIZE):
            t = (x + y) / diag
            px[x, y] = lerp(c0, c1, t)
    return img


def draw_echo_marks(img: Image.Image, *, with_alpha: bool) -> None:
    """Three concentric arcs opening right + focal dot.

    Coords reference a 1024 canvas. We slightly bias the centre to the left
    so the arcs read as expanding rightward (echo radiating outward).
    """
    draw = ImageDraw.Draw(img, "RGBA")
    cx, cy = int(SIZE * 0.36), int(SIZE * 0.50)
    stroke = int(SIZE * 0.055)

    color = (255, 255, 255, 255) if with_alpha else (255, 255, 255)

    # Three concentric arcs, sweep from -55° to +55° (rightward-opening crescents).
    # Inner is short and bright; outer rings are full color too — uniform read.
    radii = [int(SIZE * 0.18), int(SIZE * 0.30), int(SIZE * 0.42)]
    for r in radii:
        bbox = (cx - r, cy - r, cx + r, cy + r)
        draw.arc(bbox, start=-55, end=55, fill=color, width=stroke)

    # Focal dot at the arcs' centre.
    dot_r = int(SIZE * 0.045)
    draw.ellipse((cx - dot_r, cy - dot_r, cx + dot_r, cy + dot_r), fill=color)


def main() -> None:
    # 1) Full icon (iOS + master)
    full = gradient_background()
    draw_echo_marks(full, with_alpha=False)
    full.save("assets/icon.png", "PNG", optimize=True)

    # 2) Transparent foreground for Android adaptive icon. Android crops the
    # outer ~33% so we keep the mark in the safe centre square.
    fg = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    draw_echo_marks(fg, with_alpha=True)
    fg.save("assets/icon_foreground.png", "PNG", optimize=True)


if __name__ == "__main__":
    main()
