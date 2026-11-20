"""Процедурный износ для текстур Aether (стиль «Гражданская оборона / промзона»).

Слои снизу вверх: металл → грунт (красно-коричневый ГФ-021) → краска → надписи. Маски строятся из
периодического по u шума (корпуса баллонов оборачиваются без шва):
  • сколы — порог fbm, сильнее у кромок (rim) и вокруг случайных «ударов»;
  • грунт виден по краю скола, металл — в центре;
  • ржавчина — в сколах до металла и потёками вниз от них;
  • грязь — градиент к низу + пятна, пыль — сверху;
  • выцветание краски — низкочастотные пятна.
Выход: цвет (RGB), высота (для карты нормалей) и блеск (маска phong/envmap: металл блестит, краска матовая).
Всё детерминировано по seed. Только numpy и Pillow.
"""
import math
import os

import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

FONTS = r"C:\Windows\Fonts"

PRIMER = (118, 52, 38)        # грунт ГФ-021 (СССР)
PRIMER_ZINC = (150, 146, 92)  # цинкохроматный грунт (армия США/НАТО)
PRIMER_GREY = (150, 150, 146) # современный серый грунт
STEEL = (128, 128, 124)
RUST_DARK = (70, 36, 20)
RUST_LIGHT = (140, 74, 34)
STENCIL_BRIDGED = set("ОРАДВБФЯЮЁЭ0689ABDOPQR")   # буквы с замкнутыми контурами


def font(size, variation="Bold Condensed", name="bahnschrift.ttf"):
    """Шрифт надписей: Bahnschrift (DIN-подобный, кириллица) — узкое начертание как у трафаретов."""
    f = ImageFont.truetype(os.path.join(FONTS, name), size)
    try:
        f.set_variation_by_name(variation)
    except (OSError, ValueError):
        pass
    return f


def fbm(w, h, seed, octaves=((32, 0.55), (12, 0.3), (4, 0.15)), wrap_u=True):
    """Сумма октав сглаженного шума (−1..1 примерно). scale — размер ячейки в пикселях. wrap_u — шум
    периодичен по горизонтали: левый и правый край совпадают (обёртка цилиндра)."""
    rnd = np.random.default_rng(seed)
    out = np.zeros((h, w))
    for scale, amp in octaves:
        gw, gh = max(2, int(round(w / scale))), max(2, int(round(h / scale))) + 2
        g = rnd.normal(0, 1, (gh, gw))
        if wrap_u:
            # три копии периода рядом → ресайз → средняя: края совпадают без шва
            g3 = np.concatenate([g, g, g], axis=1)
            big = np.array(Image.fromarray(g3.astype(np.float32), "F").resize((3 * w, h + 2 * scale), Image.BICUBIC))
            big = big[scale:scale + h, w:2 * w]
        else:
            big = np.array(Image.fromarray(g.astype(np.float32), "F").resize((w, h + 2 * scale), Image.BICUBIC))[scale:scale + h]
        out += big * amp
    return out


def smooth(mask, r, wrap_u=True):
    """Гауссово размытие float-маски (Pillow не размывает режим F): разделимая свёртка numpy,
    по u — с переносом через шов."""
    k = max(1, int(math.ceil(r * 3)))
    x = np.arange(-k, k + 1)
    g = np.exp(-x * x / (2 * r * r))
    g /= g.sum()
    a = mask.astype(float)
    pad_u = np.concatenate([a[:, -k:], a, a[:, :k]], axis=1) if wrap_u else np.pad(a, ((0, 0), (k, k)), mode="edge")
    a = np.apply_along_axis(lambda row: np.convolve(row, g, mode="valid"), 1, pad_u)
    pad_v = np.pad(a, ((k, k), (0, 0)), mode="edge")
    return np.apply_along_axis(lambda col: np.convolve(col, g, mode="valid"), 0, pad_v)


def weathered_paint(w, h, paint, seed, wear=1.0, rims=(), rim_width=26, hits=6, rust=1.0, grime=1.0,
                    fade=1.0, gloss_paint=0.25, primer=PRIMER, base_metal=None):
    """Окрашенный металл с износом. base_metal — что под грунтом вместо стали (например, дерево ящика).
    rims — края, где краска бьётся сильнее: ('top', 'bottom', 'left', 'right').
    Возвращает dict: rgb (h,w,3 float), height (h,w 0..1), gloss (h,w 0..1), chips (маска сколов)."""
    rnd = np.random.default_rng(seed + 7)
    yy, xx = np.mgrid[0:h, 0:w].astype(float)

    # --- где краска изношена: кромки + «удары» + общий шум
    edge = np.zeros((h, w))
    for side in rims:
        d = {"top": yy, "bottom": h - 1 - yy, "left": xx, "right": w - 1 - xx}[side]
        edge = np.maximum(edge, np.clip(1 - d / rim_width, 0, 1) ** 1.5)
    for _ in range(hits):   # места ударов: овальные зоны износа
        cx, cy = rnd.uniform(0, w), rnd.uniform(0, h)
        rx, ry = rnd.uniform(12, 40), rnd.uniform(8, 26)
        dx = np.minimum(np.abs(xx - cx), w - np.abs(xx - cx))   # с переходом через шов
        edge = np.maximum(edge, np.clip(1 - (dx / rx) ** 2 - ((yy - cy) / ry) ** 2, 0, 1) * 0.8)

    # сколы — кластерами (крупные октавы), а не «песком»: середина корпуса почти чистая, бьются кромки и удары
    n_chip = fbm(w, h, seed, ((16, 0.55), (7, 0.3), (3, 0.15)))
    n_big = fbm(w, h, seed + 1, ((48, 0.7), (16, 0.3)))
    wearf = (edge * 1.3 + np.clip(n_big, 0, None) * 0.12) * wear
    chips = np.clip((n_chip * 0.7 + wearf - 0.85) * 5, 0, 1)            # 1 — краски нет
    deep = np.clip((n_chip * 0.7 + wearf - 1.1) * 5, 0, 1)              # до металла (грунт сбит)

    # --- краска: выцветание и неравномерность
    base = np.array(paint, float)[None, None, :]
    fade_n = fbm(w, h, seed + 2, ((64, 0.7), (20, 0.3)))
    lum = 1 + fade_n * 0.07 * fade + fbm(w, h, seed + 3, ((3, 1.0),)) * 0.025
    paint_rgb = base * lum[..., None]
    paint_rgb = paint_rgb + (np.array([200, 200, 195.0]) - paint_rgb) * np.clip(fade_n, 0, 1)[..., None] * 0.12 * fade

    primer = np.array(primer, float) * (1 + fbm(w, h, seed + 4, ((6, 1),))[..., None] * 0.08)
    steel = np.array(base_metal or STEEL, float) * (1 + fbm(w, h, seed + 5, ((2, 1),))[..., None] * 0.06)
    rust_mix = np.clip(fbm(w, h, seed + 6, ((6, 0.6), (2, 0.4))) * 0.5 + 0.5, 0, 1)[..., None]
    rust_col = np.array(RUST_DARK, float) * (1 - rust_mix) + np.array(RUST_LIGHT, float) * rust_mix
    metal = steel * (1 - 0.65 * rust) + rust_col * (0.65 * rust)

    under = primer * (1 - deep[..., None]) + metal * deep[..., None]
    rgb = paint_rgb * (1 - chips[..., None]) + under * chips[..., None]
    # тёмная кайма по краю скола (отслоившаяся краска)
    rim_dark = np.clip(smooth(chips, 1.2) - chips, 0, 1)
    rgb *= (1 - rim_dark[..., None] * 0.35)

    # --- потёки ржавчины вниз от сколов до металла
    if rust > 0:
        src = smooth(deep, 1.0)
        streak = np.zeros((h, w))
        acc = np.zeros(w)
        decay = 0.985
        jitter = np.clip(fbm(w, 1, seed + 8, ((3, 1),))[0] * 0.5 + 0.5, 0, 1)
        for y in range(h):
            acc = np.maximum(acc * decay, src[y] * (0.4 + 0.6 * jitter))
            streak[y] = acc
        streak = smooth(streak, 0.8) * np.clip(fbm(w, h, seed + 9, ((3, 0.6), (14, 0.4))) * 0.6 + 0.7, 0, 1)
        streak = np.clip(streak - deep, 0, 1) * 0.55 * rust
        rgb = rgb * (1 - streak[..., None]) + rust_col * streak[..., None]

    # --- грязь снизу и пыль сверху
    if grime > 0:
        g = np.clip((yy / h - 0.55) * 2.0, 0, 1) * (0.6 + 0.4 * np.clip(fbm(w, h, seed + 10, ((18, 1),)), 0, 1))
        spots = np.clip(fbm(w, h, seed + 11, ((24, 0.6), (6, 0.4))) - 0.45, 0, 1) * 0.6
        dirt = np.clip(g + spots, 0, 1) * 0.5 * grime
        rgb = rgb * (1 - dirt[..., None] * 0.55) + np.array([62, 54, 42.0]) * dirt[..., None] * 0.55
        dust = np.clip(1 - yy / (h * 0.25), 0, 1) * 0.12 * grime
        rgb = rgb + (np.array([170, 165, 150.0]) - rgb) * dust[..., None]

    height = 0.6 - chips * 0.35 - deep * 0.15 + fbm(w, h, seed + 12, ((8, 0.6), (3, 0.4))) * 0.006   # лёгкая «апельсиновая корка» эмали
    gloss = gloss_paint * (1 - chips) + chips * (1 - deep) * 0.1 + deep * (0.55 * (1 - 0.8 * rust))
    return {"rgb": rgb, "height": height, "gloss": np.clip(gloss, 0, 1), "chips": chips}


def fit_font(text, max_w, size, variation="Bold Condensed", min_size=10):
    """Наибольший размер шрифта ≤ size, при котором надпись не шире max_w пикселей."""
    while size > min_size:
        f = font(size, variation)
        bb = ImageDraw.Draw(Image.new("L", (1, 1))).textbbox((0, 0), text, font=f)
        if bb[2] - bb[0] <= max_w:
            return f
        size -= 2
    return font(min_size, variation)


def stencil_text(layer, text, fnt, center, color, seed=0, squash=1.0, bridges=True, worn=None, alpha=0.95):
    """Надпись по трафарету поверх слоя (dict из weathered_paint).
    squash — сжатие по вертикали (тексели цилиндра неквадратные). bridges — перемычки трафарета:
    узкие вертикальные просветы через каждую букву. Краска надписи облезает по маске сколов слоя
    и чуть «пылит» по краю (напыление). Изменяет layer на месте."""
    h, w = layer["height"].shape
    tmp = Image.new("L", (1, 1))
    bb = ImageDraw.Draw(tmp).textbbox((0, 0), text, font=fnt)
    tw, th = bb[2] - bb[0] + 8, bb[3] - bb[1] + 8
    m = Image.new("L", (tw, th), 0)
    d = ImageDraw.Draw(m)
    d.text((4 - bb[0], 4 - bb[1]), text, font=fnt, fill=255)
    if bridges:   # перемычки — только у букв с замкнутым контуром (иначе их не вырезать из трафарета)
        x = 4 - bb[0]
        for ch in text:
            cw = d.textlength(ch, font=fnt)
            if ch in STENCIL_BRIDGED:
                bx = x + cw * 0.5
                d.rectangle([bx - max(1, cw * 0.035), 0, bx + max(1, cw * 0.035), th * 0.3], fill=0)
            x += cw
    if squash != 1.0:
        m = m.resize((tw, max(1, int(th * squash))), Image.LANCZOS)
    a = np.array(m, float) / 255
    spray = smooth(a, 1.6) * 0.25            # напыление вокруг букв
    a = np.clip(np.maximum(a, spray), 0, 1)
    cx, cy = center
    full = np.zeros((h, w))
    x0, y0 = int(cx - a.shape[1] / 2), int(cy - a.shape[0] / 2)
    for k in (-w, 0, w):                     # перенос через шов по u
        xs0, xs1 = max(0, x0 + k), min(w, x0 + k + a.shape[1])
        ys0, ys1 = max(0, y0), min(h, y0 + a.shape[0])
        if xs1 > xs0 and ys1 > ys0:
            full[ys0:ys1, xs0:xs1] = np.maximum(full[ys0:ys1, xs0:xs1],
                                                a[ys0 - y0:ys1 - y0, xs0 - (x0 + k):xs1 - (x0 + k)])
    holes = np.clip(fbm(w, h, seed + 30, ((3, 0.6), (8, 0.4))) * 0.5 + 0.5, 0, 1)
    keep = (1 - layer["chips"]) * np.clip(1.25 - holes * (0.5 if worn is None else worn), 0, 1)
    full = full * keep * alpha
    layer["rgb"] = layer["rgb"] * (1 - full[..., None]) + np.array(color, float) * full[..., None]
    layer["height"] = layer["height"] + full * 0.03


def band(layer, y0, y1, color, seed=0):
    """Цветная полоса по окружности (поверх краски, облезает вместе с ней)."""
    h, w = layer["height"].shape
    a = np.zeros((h, w))
    a[int(y0):int(y1)] = 1
    a = smooth(a, 0.7) * (1 - layer["chips"])
    edge_n = np.clip(fbm(w, h, seed + 40, ((2, 1),)) * 0.3 + 1, 0, 1)
    a *= edge_n
    layer["rgb"] = layer["rgb"] * (1 - a[..., None]) + np.array(color, float) * (1 + fbm(w, h, seed + 41, ((40, 1),)) * 0.05)[..., None] * a[..., None]


def stamp(layer, text, fnt, center, seed=0, squash=1.0):
    """Выбитое клеймо (вдавлено в металл): темнее и ниже по высоте, без цвета."""
    h, w = layer["height"].shape
    tmp = ImageDraw.Draw(Image.new("L", (1, 1)))
    bb = tmp.textbbox((0, 0), text, font=fnt)
    tw, th = bb[2] - bb[0] + 4, bb[3] - bb[1] + 4
    m = Image.new("L", (tw, th), 0)
    ImageDraw.Draw(m).text((2 - bb[0], 2 - bb[1]), text, font=fnt, fill=255)
    if squash != 1.0:
        m = m.resize((tw, max(1, int(th * squash))), Image.LANCZOS)
    a = np.array(m, float) / 255
    cx, cy = center
    x0, y0 = int(cx - a.shape[1] / 2), int(cy - a.shape[0] / 2)
    xs1, ys1 = min(w, x0 + a.shape[1]), min(h, y0 + a.shape[0])
    if x0 < 0 or y0 < 0:
        return
    sub = a[:ys1 - y0, :xs1 - x0]
    layer["rgb"][y0:ys1, x0:xs1] *= (1 - sub[..., None] * 0.35)
    layer["height"][y0:ys1, x0:xs1] -= sub * 0.12


def to_image(layer):
    return Image.fromarray(np.uint8(np.clip(layer["rgb"], 0, 255)), "RGB")


def normal_map(height, strength=4.0, wrap_u=True):
    """Карта нормалей в касательном пространстве по высоте. Конвенция Source — DirectX: зелёный канал
    направлен ВНИЗ по картинке (Y−), поэтому ny = −(−dh/dy). Альфа — отдельно (маска блеска)."""
    hgt = height.astype(float)
    if wrap_u:
        dx = (np.roll(hgt, -1, axis=1) - np.roll(hgt, 1, axis=1)) * 0.5
    else:
        dx = np.gradient(hgt, axis=1)
    dy = np.gradient(hgt, axis=0)                     # производная вниз по картинке
    k = strength * 255 / 64
    nx, ny, nz = -dx * k, -dy * k, np.ones_like(hgt)  # нормаль наклонена от подъёма; Y вниз (DirectX)
    ln = np.sqrt(nx * nx + ny * ny + nz * nz)
    return np.dstack([nx / ln, ny / ln, nz / ln]) * 0.5 + 0.5


def normal_image(height, gloss, strength=4.0):
    n = normal_map(height, strength)
    rgba = np.dstack([n, gloss[..., None]])
    return Image.fromarray(np.uint8(np.clip(rgba * 255, 0, 255)), "RGBA")


def decal(layer, img, center, squash=1.0, wear=0.3, seed=0, gloss=0.35):
    """Наклейка (RGBA Pillow) поверх слоя: сжатие по вертикали под тексели цилиндра, перенос через шов,
    потёртость — дырки по шуму и по сколам краски под ней. Изменяет layer на месте."""
    h, w = layer["height"].shape
    if squash != 1.0:
        img = img.resize((img.size[0], max(1, int(img.size[1] * squash))), Image.LANCZOS)
    a = np.asarray(img, float)
    rgb, al = a[..., :3], a[..., 3] / 255
    cx, cy = center
    x0, y0 = int(cx - a.shape[1] / 2), int(cy - a.shape[0] / 2)
    full_a, full_rgb = np.zeros((h, w)), np.zeros((h, w, 3))
    for k in (-w, 0, w):
        xs0, xs1 = max(0, x0 + k), min(w, x0 + k + a.shape[1])
        ys0, ys1 = max(0, y0), min(h, y0 + a.shape[0])
        if xs1 > xs0 and ys1 > ys0:
            sx0, sy0 = xs0 - (x0 + k), ys0 - y0
            full_a[ys0:ys1, xs0:xs1] = al[sy0:sy0 + ys1 - ys0, sx0:sx0 + xs1 - xs0]
            full_rgb[ys0:ys1, xs0:xs1] = rgb[sy0:sy0 + ys1 - ys0, sx0:sx0 + xs1 - xs0]
    # потёртость — по краям наклейки (середина цела): шум с порогом по квантилю (доля ≈ wear у края),
    # вес края = 1 − размытая альфа. Сколы краски под наклейкой не видны — она лежит поверх.
    keep = 1.0
    if wear > 0:
        n = fbm(w, h, seed + 50, ((6, 0.6), (3, 0.4)))
        edge = np.clip((1 - smooth(full_a, 5)) * 2.5, 0, 1)
        n = n + edge * 1.5
        keep = 1 - np.clip((n - np.quantile(n[full_a > 0.5], 1 - wear)) * 4, 0, 1) if (full_a > 0.5).any() else 1.0
    full_a = full_a * keep
    layer["rgb"] = layer["rgb"] * (1 - full_a[..., None]) + full_rgb * full_a[..., None]
    layer["height"] = layer["height"] * (1 - full_a) + 0.63 * full_a   # наклейка ровная: рельеф сколов под ней не виден
    layer["gloss"] = layer["gloss"] * (1 - full_a) + gloss * full_a


def wood_grain(layer, seed, plank=25, strength=1.0):
    """Доски поверх слоя: продольные волокна (синус по строкам с искажением шумом), тёмные щели между
    досками каждые plank пикселей (по вертикали), чуть разный тон досок. Меняет цвет и высоту на месте."""
    h, w = layer["height"].shape
    yy = np.mgrid[0:h, 0:w][0].astype(float)
    warp = fbm(w, h, seed + 60, ((24, 0.7), (8, 0.3)))
    grain = np.sin((yy + warp * 2.5) * 1.3) * 0.5 + 0.5
    tone = np.zeros((h, w))
    rnd = np.random.default_rng(seed + 61)
    for y0 in range(0, h, plank):
        tone[y0:y0 + plank] = rnd.uniform(-0.06, 0.06)
    gap = ((yy % plank) < 1.6).astype(float)
    k = (1 + (grain - 0.5) * 0.05 * strength + tone)[..., None]
    layer["rgb"] = layer["rgb"] * k * (1 - gap[..., None] * 0.55)
    layer["height"] = layer["height"] + (grain - 0.5) * 0.012 * strength - gap * 0.25
