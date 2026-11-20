"""Обложка (превью) Aether для Steam Workshop в стиле «логотип + рендер», как у LVS / GWater.

    python -I tools/make_cover.py            # все варианты → release/workshop/cover_<v>.jpg (1024) + _512
    python -I tools/make_cover.py --variant a
    python -I tools/make_cover.py --variant d   # d, e, f — на рендерах Blender (tools/blender_scene.py)

Всё генерируется: фон, клубы цветного дыма (fBm-шум, псевдоосвещение по градиенту), модели — тем же
программным растеризатором, что иконки (make_models.raster_mesh, текстуры из build/models/tex после
make_models.py), шрифты — системные Windows. Превью Workshop: JPG, квадрат, < 1 МБ.
"""
import argparse
import math
import os
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import make_models as mm  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "release", "workshop")
TEX = os.path.join(mm.BUILD, "tex")
S = 1024


def font(names, size, variation=None):
    for n in names:
        try:
            f = ImageFont.truetype(os.path.join(mm.FONTS, n), size)
            if variation:
                try:
                    f.set_variation_by_name(variation)
                except (OSError, ValueError):
                    pass
            return f
        except OSError:
            continue
    return ImageFont.load_default()


# ------------------------------------------------------------------------------------------------
# Дым: fBm-шум × эллиптическая форма клуба, освещение сверху-слева по разности сдвинутого шума
# ------------------------------------------------------------------------------------------------
def fbm(h, w, seed, octaves=6, base=3):
    rng = np.random.default_rng(seed)
    out, amp, total = np.zeros((h, w)), 1.0, 0.0
    for o in range(octaves):
        n = base * 2 ** o
        g = rng.random((n + 1, n + 1))
        img = Image.fromarray(np.uint8(g * 255)).resize((w, h), Image.BICUBIC)
        out += amp * np.asarray(img, float) / 255
        total += amp
        amp *= 0.55
    return out / total


_PUFF = None


def puff_sprite():
    """Мягкий клуб 256×256: радиальный спад × шум (неровный край), как спрайт облака в игре."""
    global _PUFF
    if _PUFF is None:
        y, x = np.mgrid[0:256, 0:256].astype(float)
        r = np.sqrt((x - 128) ** 2 + (y - 128) ** 2) / 128
        n = fbm(256, 256, 7, octaves=5, base=2)
        a = np.clip((1 - r) * 1.6 + (n - 0.5) * 1.1, 0, 1) ** 1.6
        _PUFF = Image.fromarray(np.uint8(a * 255), "L")
    return _PUFF


def plume(canvas, cx, base_y, height, width, color, seed, n=160, r0=60, alpha=0.55):
    """Столб дыма из сотен клубов: снизу узко и плотно, кверху шире; верх клубов светлее (свет сверху),
    у каждого — тёмная «подошва» со сдвигом вниз-вправо (объём)."""
    rng = np.random.default_rng(seed)
    col = np.array(color, float)
    puffs = []
    for _ in range(n):
        t = rng.random() ** 0.75                       # 0 — у источника, 1 — верх столба
        x = cx + rng.normal(0, 1) * width * (0.25 + 0.75 * t)
        y = base_y - t * height + rng.normal(0, 1) * r0 * 0.3
        r = r0 * (0.55 + 0.9 * t) * rng.uniform(0.7, 1.3)
        puffs.append((y, x, r, t))
    puffs.sort(key=lambda p: -p[0])                    # снизу вверх: верхние клубы ложатся поверх
    sprite = puff_sprite()
    for y, x, r, t in puffs:
        size = max(8, int(r * 2))
        a = sprite.resize((size, size), Image.BILINEAR)
        lit = np.clip(col * (0.92 + 0.35 * t), 0, 255)
        dark = col * 0.55
        for rgb, k, dx, dy in ((dark, 0.75, 0.16, 0.2), (lit, 1.0, 0, 0)):
            layer = Image.new("RGBA", (size, size), tuple(int(v) for v in rgb) + (0,))
            layer.putalpha(a.point(lambda v, k=k: int(v * alpha * k)))
            canvas.alpha_composite(layer, (int(x - size / 2 + dx * size), int(y - size / 2 + dy * size)))


def background(top=(12, 16, 20), bottom=(30, 34, 38), glow=(70, 82, 70), gx=0.5, gy=0.42):
    y, x = np.mgrid[0:S, 0:S].astype(float) / S
    t = y[..., None]
    rgb = np.array(top, float) * (1 - t) + np.array(bottom, float) * t
    r = np.sqrt((x - gx) ** 2 + (y - gy) ** 2)
    rgb += np.array(glow, float)[None, None, :] * np.clip(1 - r * 1.8, 0, 1)[..., None] ** 2
    vign = np.clip(1.15 - r * 0.7, 0.55, 1)[..., None]      # виньетка
    return Image.fromarray(np.uint8(np.clip(rgb * vign, 0, 255))).convert("RGBA")


# ------------------------------------------------------------------------------------------------
# Модели
# ------------------------------------------------------------------------------------------------
def render(model, swap=None, yaw=30, pitch=10, size=700, fill=0.9):
    mesh = mm.MODELS[model][0]()[0]

    def lookup(mat):
        name = swap if (swap and mat.split("_")[0] == swap.split("_")[0]) else mat
        return Image.open(os.path.join(TEX, name + ".png")).convert("RGB")
    return mm.raster_mesh(mesh, lookup, yaw, pitch, size, 2, fill)


def shadow_of(obj, blur=18, alpha=150):
    a = obj.split()[3].filter(ImageFilter.GaussianBlur(blur))
    sh = Image.new("RGBA", obj.size, (0, 0, 0, 0))
    sh.putalpha(a.point(lambda v: v * alpha // 255))
    return sh


def paste_obj(canvas, obj, x, y):
    canvas.alpha_composite(shadow_of(obj), (x + 14, y + 22))
    canvas.alpha_composite(obj, (x, y))


# ------------------------------------------------------------------------------------------------
# Логотип
# ------------------------------------------------------------------------------------------------
def tracked_text(d, xy, text, fnt, fill, tracking=0, anchor_center=True, stroke=0, stroke_fill=None):
    widths = [d.textlength(ch, font=fnt) for ch in text]
    total = sum(widths) + tracking * (len(text) - 1)
    x, y = xy
    if anchor_center:
        x -= total / 2
    for ch, w in zip(text, widths):
        d.text((x, y), ch, font=fnt, fill=fill, stroke_width=stroke, stroke_fill=stroke_fill)
        x += w + tracking
    return total


def logo(canvas, cy, accent=(196, 214, 70), title_size=210, sub=True):
    """«AETHER» с градиентом и тенью, подзаголовок и строка-тег."""
    W = S
    title_f = font(["bahnschrift.ttf", "impact.ttf"], title_size, "Bold Condensed")
    sub_f = font(["bahnschrift.ttf", "arialbd.ttf"], 44, "SemiBold")
    tag_f = font(["bahnschrift.ttf", "arialbd.ttf"], 30, "SemiLight")

    mask = Image.new("L", (W, title_size + 80), 0)
    dm = ImageDraw.Draw(mask)
    tracked_text(dm, (W / 2, 10), "AETHER", title_f, 255, tracking=10)
    grad = np.linspace(255, 196, mask.size[1])[:, None].repeat(W, 1)
    fill = Image.fromarray(np.uint8(np.dstack([grad, grad, grad + 6 * 0])), "RGB").convert("RGBA")
    fill.putalpha(mask)
    sh = Image.new("RGBA", mask.size, (0, 0, 0, 0))
    sh.putalpha(mask.filter(ImageFilter.GaussianBlur(10)).point(lambda v: v * 220 // 255))
    glow = Image.new("RGBA", mask.size, accent + (0,))
    glow.putalpha(mask.filter(ImageFilter.GaussianBlur(26)).point(lambda v: v * 120 // 255))
    canvas.alpha_composite(glow, (0, cy))
    canvas.alpha_composite(sh, (6, cy + 10))
    canvas.alpha_composite(fill, (0, cy))
    if not sub:
        return
    d = ImageDraw.Draw(canvas)
    y = cy + title_size + 6
    w = tracked_text(d, (W / 2, y), "VOLUMETRIC SMOKE & GAS DYNAMICS", sub_f, (238, 240, 236), tracking=4,
                     stroke=3, stroke_fill=(10, 12, 14))
    d.rectangle([W / 2 - w / 2, y + 62, W / 2 + w / 2, y + 67], fill=accent)
    tracked_text(d, (W / 2, y + 82), "18 GASES  ·  PURE GLUA  ·  MULTIPLAYER", tag_f, (200, 206, 200),
                 tracking=3, stroke=2, stroke_fill=(10, 12, 14))


# ------------------------------------------------------------------------------------------------
# Варианты
# ------------------------------------------------------------------------------------------------
def variant_a():
    """Противогаз в центре в клубах хлора, красного сигнального и белого дыма; логотип снизу."""
    c = background()
    plume(c, 230, 760, 560, 150, (196, 212, 64), 11, 170, 70)
    plume(c, 800, 760, 560, 150, (220, 58, 46), 12, 170, 70)
    plume(c, 520, 700, 520, 190, (226, 228, 232), 13, 150, 75, 0.45)
    plume(c, 90, 1010, 200, 160, (44, 42, 40), 14, 80, 80, 0.6)
    plume(c, 940, 1010, 200, 160, (44, 42, 40), 15, 80, 80, 0.6)
    mask = render("gasmask", None, 28, 6, 600, 0.95)
    paste_obj(c, mask, 212, 80)
    logo(c, 640)
    return c


def variant_b():
    """Три баллона (хлор, тактический дым, сигнальный красный); из вентилей поднимается их газ; логотип сверху."""
    c = background(glow=(60, 66, 74), gy=0.62)
    xs = (230, 512, 794)
    cols = ((196, 212, 64), (232, 234, 238), (220, 58, 46))
    for i, (x, col) in enumerate(zip(xs, cols)):
        plume(c, x, 520, 470, 70, col, 21 + i, 150, 52, 0.6)
    logo(c, 30, accent=(220, 58, 46), title_size=190)
    for i, (gas, x) in enumerate((("chlorine", xs[0]), ("smoke", xs[1]), ("signal_red", xs[2]))):
        cyl = render("gas_cylinder", "cylinder_" + gas, 18 + i * 8, 6, 460, 0.98)
        paste_obj(c, cyl, x - 230, 500)
    return c


def variant_c():
    """Минимализм: большой логотип в кольце цветных дымов, маленький противогаз над ним."""
    c = background(top=(10, 12, 16), bottom=(22, 24, 28), glow=(40, 46, 52))
    cols = [(196, 212, 64), (220, 58, 46), (90, 140, 230), (140, 72, 196), (240, 128, 36), (228, 230, 234)]
    for i, col in enumerate(cols):
        a = 2 * math.pi * i / len(cols) + math.pi / 2
        x, y = 512 + math.cos(a) * 360, 600 + math.sin(a) * 300
        plume(c, x, y + 140, 260, 110, col, 31 + i, 110, 60, 0.55)
    mask = render("gasmask", None, 32, 8, 320, 0.95)
    paste_obj(c, mask, 352, 150)
    logo(c, 470, accent=(140, 200, 255), title_size=200)
    return c


# ------------------------------------------------------------------------------------------------
# Варианты на рендерах Blender (0.12: новые модели). Сначала:
#   python -I tools/export_props.py
#   blender -b --factory-startup --python tools/blender_scene.py -- cover_a|cover_b|cover_c --render
# Рендеры — release/workshop/blender/cover_<x>.png; здесь — затемнение под надпись и логотип.
# ------------------------------------------------------------------------------------------------
BLENDER = os.path.join(OUT, "blender")


def blender_bg(scene, dark_top=0.0, dark_bottom=0.0):
    img = Image.open(os.path.join(BLENDER, scene + ".png")).convert("RGB").resize((S, S), Image.LANCZOS)
    a = np.asarray(img, float)
    y = np.linspace(0, 1, S)[:, None, None]
    k = 1 - dark_top * np.clip(1 - y / 0.42, 0, 1) ** 1.6 - dark_bottom * np.clip((y - 0.55) / 0.45, 0, 1) ** 1.4
    return Image.fromarray(np.uint8(np.clip(a * k, 0, 255))).convert("RGBA")


def variant_d():
    """Противогаз ГП-7 на ящике ОЗК в столбах хлора, сигнального и белого дыма; логотип снизу."""
    c = blender_bg("cover_a", dark_bottom=0.75)
    logo(c, 640, accent=(196, 214, 70))
    return c


def variant_e():
    """Три баллона (СССР, НАТО, современный) с дымом из вентилей; логотип сверху."""
    c = blender_bg("cover_b", dark_top=0.55)
    logo(c, 26, accent=(220, 58, 46), title_size=190)
    return c


def variant_f():
    """Горящие фаеры, граната НАТО, анализатор и противогаз на полу, цветной дым; логотип сверху."""
    c = blender_bg("cover_c", dark_top=0.6)
    logo(c, 26, accent=(140, 200, 255), title_size=190)
    return c


VARIANTS = {"a": variant_a, "b": variant_b, "c": variant_c, "d": variant_d, "e": variant_e, "f": variant_f}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--variant", default="")
    args = ap.parse_args()
    os.makedirs(OUT, exist_ok=True)
    names = [args.variant] if args.variant else list(VARIANTS)
    for v in names:
        img = VARIANTS[v]().convert("RGB")
        img.save(os.path.join(OUT, f"cover_{v}.jpg"), quality=92)
        img.resize((512, 512), Image.LANCZOS).save(os.path.join(OUT, f"cover_{v}_512.jpg"), quality=92)
        print("cover", v, os.path.getsize(os.path.join(OUT, f"cover_{v}.jpg")) // 1024, "KB")


if __name__ == "__main__":
    main()
