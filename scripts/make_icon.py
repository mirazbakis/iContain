"""iContain app icon: a glass container holding a 2x2 grid of app tiles, each with a
glossy knob, on a slate squircle. Rendered at 4x and downsampled."""
import sys
from PIL import Image, ImageDraw, ImageFilter, ImageChops

S = 4
N = 1024 * S
out = sys.argv[1]


def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(len(a)))


def vgradient(w, h, top, bottom):
    col = Image.new("RGBA", (1, h))
    for y in range(h):
        col.putpixel((0, y), lerp(top, bottom, y / max(1, h - 1)))
    return col.resize((w, h))


def rrect_mask(w, h, r, box=None, size=None):
    size = size or (w, h)
    m = Image.new("L", size, 0)
    d = ImageDraw.Draw(m)
    box = box or (0, 0, w - 1, h - 1)
    d.rounded_rectangle(box, r, fill=255)
    return m


def paste_grad(base, box, r, top, bottom):
    x0, y0, x1, y1 = box
    w, h = x1 - x0, y1 - y0
    g = vgradient(w, h, top, bottom)
    m = rrect_mask(w, h, r)
    base.paste(g, (x0, y0), m)


def shadow(base, box, r, offset, blur, alpha):
    x0, y0, x1, y1 = box
    layer = Image.new("RGBA", base.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    d.rounded_rectangle((x0, y0 + offset, x1, y1 + offset), r, fill=(10, 14, 30, alpha))
    layer = layer.filter(ImageFilter.GaussianBlur(blur))
    base.alpha_composite(layer)


def rim(base, box, r, width, top_alpha, bottom_alpha, color=(255, 255, 255)):
    """A thin highlight ring that fades from top to bottom, like the reference's glass edge."""
    x0, y0, x1, y1 = box
    w, h = x1 - x0, y1 - y0
    outer = rrect_mask(w, h, r)
    inner = rrect_mask(w, h, max(0, r - width), box=(width, width, w - 1 - width, h - 1 - width))
    ring = ImageChops.subtract(outer, inner)
    fade = vgradient(1, h, (top_alpha,), (bottom_alpha,)).convert("L").resize((w, h))
    ring = ImageChops.multiply(ring, fade)
    layer = Image.new("RGBA", (w, h), color + (0,))
    layer.putalpha(ring)
    base.alpha_composite(layer, (x0, y0))


def inner_shadow(base, box, r, depth, alpha):
    """Darkens the top inside edge so a shape reads as pressed in."""
    x0, y0, x1, y1 = box
    w, h = x1 - x0, y1 - y0
    m = rrect_mask(w, h, r)
    shifted = Image.new("L", (w, h), 0)
    shifted.paste(m, (0, depth))
    edge = ImageChops.subtract(m, shifted).filter(ImageFilter.GaussianBlur(depth * 0.8))
    edge = ImageChops.multiply(edge, m)
    layer = Image.new("RGBA", (w, h), (20, 24, 45, 0))
    layer.putalpha(edge.point(lambda v: v * alpha // 255))
    base.alpha_composite(layer, (x0, y0))


def knob(base, cx, cy, rad, live=False):
    if live:
        halo = Image.new("RGBA", base.size, (0, 0, 0, 0))
        ImageDraw.Draw(halo).ellipse((cx - rad * 1.9, cy - rad * 1.9, cx + rad * 1.9, cy + rad * 1.9), fill=(110, 160, 255, 150))
        base.alpha_composite(halo.filter(ImageFilter.GaussianBlur(rad * 0.6)))
    shadow(base, (cx - rad, cy - rad, cx + rad, cy + rad), rad, int(rad * 0.25), rad * 0.35, 120)
    top, bottom = ((150, 190, 255, 255), (64, 120, 240, 255)) if live else ((255, 255, 255, 255), (222, 226, 240, 255))
    paste_grad(base, (cx - rad, cy - rad, cx + rad, cy + rad), rad, top, bottom)
    rim(base, (cx - rad, cy - rad, cx + rad, cy + rad), rad, max(2, rad // 10), 0, 140, color=(150, 156, 185))


img = Image.new("RGBA", (N, N), (0, 0, 0, 0))

# Background: slate with a cool blue lean, lighter at the top.
img.paste(vgradient(N, N, (134, 142, 178, 255), (66, 73, 104, 255)), (0, 0))
glow = Image.new("RGBA", (N, N), (0, 0, 0, 0))
ImageDraw.Draw(glow).ellipse((-N * 0.1, -N * 0.6, N * 1.1, N * 0.35), fill=(255, 255, 255, 34))
img.alpha_composite(glow.filter(ImageFilter.GaussianBlur(N * 0.16)))

# The container: a raised glass slab.
m = int(N * 0.17)
box = (m, m, N - m, N - m)
cr = int(N * 0.16)
shadow(img, box, cr, int(N * 0.03), N * 0.035, 150)
paste_grad(img, box, cr, (226, 229, 243, 255), (170, 176, 204, 255))
rim(img, box, cr, int(N * 0.008), 255, 40)

# Four app tiles, pressed into the slab, each with a knob.
pad = int(N * 0.06)
gap = int(N * 0.045)
inner = box[2] - box[0] - 2 * pad
tile = (inner - gap) // 2
tr = int(tile * 0.3)
knob_r = int(tile * 0.2)
for row in range(2):
    for col in range(2):
        x0 = box[0] + pad + col * (tile + gap)
        y0 = box[1] + pad + row * (tile + gap)
        t = (x0, y0, x0 + tile, y0 + tile)
        paste_grad(img, t, tr, (186, 191, 215, 255), (150, 156, 184, 255))
        inner_shadow(img, t, tr, int(tile * 0.07), 170)
        rim(img, t, tr, int(N * 0.004), 0, 210)
        knob(img, x0 + tile // 2, y0 + tile // 2, knob_r, live=(row, col) == (0, 1))

img = img.resize((1024, 1024), Image.LANCZOS).convert("RGB")
img.save(out)
print("saved", out)
