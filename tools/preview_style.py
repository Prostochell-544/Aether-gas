"""Превью стиля пропов без компиляции в игру: рендер «было / стало» программным растеризатором
make_models.raster_mesh. Пишет build/preview/<name>.png.
usage: python -I tools/preview_style.py [cylinder]
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import numpy as np                     # noqa: E402
from PIL import Image, ImageDraw       # noqa: E402

import make_models as M                # noqa: E402

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "build", "preview")


def shade_with_normals(color, nrm):
    """Грубо «запечь» карту нормалей в цвет для превью (растеризатор не умеет нормали): свет сверху-слева,
    плюс блик по маске блеска — видно сколы, клеймо и рельеф."""
    c = np.asarray(color, float)
    n = np.asarray(nrm, float) / 255
    nv = n[..., :3] * 2 - 1
    L = np.array([-0.45, -0.55, 0.7]); L /= np.linalg.norm(L)   # свет сверху-слева (G — вниз, DirectX)
    lam = np.clip((nv @ L) / L[2], 0.8, 1.15)
    spec = np.clip(nv @ L, 0, 1) ** 24 * n[..., 3] * 90
    return Image.fromarray(np.uint8(np.clip(c * lam[..., None] + spec[..., None], 0, 255)))


def label(img, text):
    d = ImageDraw.Draw(img)
    d.rectangle([0, 0, img.size[0], 30], fill=(20, 20, 22))
    d.text((10, 7), text, fill=(230, 230, 230), font=M.font("bahnschrift.ttf", 18))
    return img


def cylinder(gases=("chlorine", "hydrogen", "ammonia", "sarin", "co2", "signal_red")):
    """Сетка: строка — газ, столбцы — сейчас / СССР / НАТО / современный (вид спереди)."""
    mesh = M.model_canister()[0]
    T = 380
    cols = [("сейчас", None), ("СССР", "su"), ("НАТО", "nato"), ("современный", "modern")]
    sheet = Image.new("RGB", (T * len(cols) * 2, T * ((len(gases) + 1) // 2)), (30, 30, 30))
    os.makedirs(OUT, exist_ok=True)
    for i, g in enumerate(gases):
        for j, (title, style) in enumerate(cols):
            if style is None:
                tex = M.tex_cylinder(g)
            else:
                col, nrm = M.tex_cylinder_styled(g, style)
                tex = shade_with_normals(col, nrm)
                col.save(os.path.join(OUT, f"cyl_{style}_{g}_color.png"))
            img = M.raster_mesh(mesh, lambda _m, t=tex: t, yaw=0, pitch=10, size=T, ss=2, fill=0.92)
            bg = Image.new("RGBA", img.size, (58, 60, 62, 255))
            tile = label(Image.alpha_composite(bg, img).convert("RGB"), f"{title}: {g}")
            sheet.paste(tile, ((i % 2) * T * len(cols) + j * T, (i // 2) * T))
    p = os.path.join(OUT, "cylinder_styles.jpg")
    sheet.save(p, quality=90)
    print(p)




def items():
    """Противогаз, газоанализатор, распылитель: по три ракурса (бак распылителя тонирован как в игре)."""
    T = 420
    rows = []
    mask_c, mask_n = M.tex_gasmask()
    an_c, an_n = M.tex_analyzer()
    sp_c, sp_n = M.tex_sprayer()
    tk_c, tk_n = M.tex_sprayer_tank()
    tint = np.array([196, 206, 62], float) / 255           # бак в цвет хлора
    tk = shade_with_normals(Image.fromarray(np.uint8(np.asarray(tk_c, float) * tint)), tk_n)
    texs = {"gasmask": shade_with_normals(mask_c, mask_n), "analyzer": shade_with_normals(an_c, an_n),
            "sprayer": shade_with_normals(sp_c, sp_n), "sprayer_tank": tk}
    for fn, views in ((M.model_gasmask, ((30, 10), (90, 5), (-40, 20))),
                      (M.model_analyzer, ((20, 12), (60, 15), (200, 10))),
                      (M.model_sprayer, ((90, 8), (60, 15), (-60, 15)))):
        mesh = fn()[0]
        row = []
        for yaw, pitch in views:
            img = M.raster_mesh(mesh, lambda m: texs[m], yaw=yaw, pitch=pitch, size=T, ss=2, fill=0.85)
            row.append(Image.alpha_composite(Image.new("RGBA", img.size, (58, 60, 62, 255)), img).convert("RGB"))
        rows.append(row)
    sheet = Image.new("RGB", (T * 3, T * len(rows)))
    for i, row in enumerate(rows):
        for j, t in enumerate(row):
            sheet.paste(t, (j * T, i * T))
    os.makedirs(OUT, exist_ok=True)
    p = os.path.join(OUT, "items_style.jpg")
    sheet.save(p, quality=90)
    print(p)


if __name__ == "__main__":
    {"cylinder": cylinder, "items": items}[sys.argv[1] if len(sys.argv) > 1 else "cylinder"]()
