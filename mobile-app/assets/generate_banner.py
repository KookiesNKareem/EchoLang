"""
README hero banner. Mirrors the icon visually so the repo and the app share
an identity. 1600×500 lets GitHub render it without aggressive scaling.
"""
from __future__ import annotations

from PIL import Image, ImageDraw, ImageFont

W, H = 1600, 500


def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))


def load_font(size: int) -> ImageFont.ImageFont:
    # Try a few system fonts in order; fall back to PIL default if none load.
    for path in [
        "/System/Library/Fonts/SFNS.ttf",
        "/System/Library/Fonts/Helvetica.ttc",
        "/Library/Fonts/Arial.ttf",
    ]:
        try:
            return ImageFont.truetype(path, size)
        except OSError:
            pass
    return ImageFont.load_default()


def main() -> None:
    img = Image.new("RGB", (W, H))
    c0 = (15, 35, 64)
    c1 = (45, 212, 191)
    px = img.load()
    diag = (W - 1) + (H - 1)
    for y in range(H):
        for x in range(W):
            t = (x + y) / diag
            px[x, y] = lerp(c0, c1, t)

    draw = ImageDraw.Draw(img, "RGBA")

    # Echo mark on the left, sized to feel iconographic but not dominant.
    cx, cy = 230, H // 2
    stroke = 16
    white = (255, 255, 255, 255)
    for r in (60, 110, 160):
        draw.arc((cx - r, cy - r, cx + r, cy + r), start=-55, end=55,
                 fill=white, width=stroke)
    draw.ellipse((cx - 14, cy - 14, cx + 14, cy + 14), fill=white)

    # Wordmark + tagline. Two lines, left-aligned next to the mark.
    title_font = load_font(132)
    tag_font = load_font(38)
    sub_font = load_font(26)

    text_x = 470
    draw.text((text_x, H // 2 - 110), "EchoLang", font=title_font, fill=(255, 255, 255))
    draw.text((text_x, H // 2 + 50), "Offline classroom AI for any language.",
              font=tag_font, fill=(220, 240, 240))
    draw.text((text_x, H // 2 + 110), "Pi 5 + on-device Gemma 4 E2B  ·  No cloud, no accounts.",
              font=sub_font, fill=(170, 215, 215))

    import os
    os.makedirs("../assets", exist_ok=True)
    img.save("../assets/banner.png", "PNG", optimize=True)


if __name__ == "__main__":
    main()
