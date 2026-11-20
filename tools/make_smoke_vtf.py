"""Генерирует materials/aether/smoke_puff.vtf (+ .vmt) — атлас 2×2 мягких клубов дыма, 256×256 BGRA8888,
полная цепочка mip-уровней. Без внешних зависимостей.

    python -I tools/make_smoke_vtf.py

Формат VTF 7.2: заголовок 65 байт (pack 1) + выравнивание до 80, затем mip-уровни от меньшего к большему.
"""
import math
import os
import random
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

_REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# клон репозитория (addon.json рядом с tools/) — пишем в него; иначе — в живой аддон в GMod
ADDON = os.environ.get("AETHER_ADDON") or (_REPO if os.path.exists(os.path.join(_REPO, "addon.json")) else
                                           r"C:\Program Files (x86)\Steam\steamapps\common\GarrysMod\garrysmod\addons\aether_gaslua")
SIZE = 256
CELL = SIZE // 2


def value_noise(seed, freq):
    rnd = random.Random(seed)
    grid = [[rnd.random() for _ in range(freq + 1)] for _ in range(freq + 1)]

    def sample(u, v):  # u, v ∈ [0,1]
        x, y = u * freq, v * freq
        x0, y0 = int(x), int(y)
        x1, y1 = min(x0 + 1, freq), min(y0 + 1, freq)
        fx, fy = x - x0, y - y0
        fx, fy = fx * fx * (3 - 2 * fx), fy * fy * (3 - 2 * fy)
        a = grid[y0][x0] + (grid[y0][x1] - grid[y0][x0]) * fx
        b = grid[y1][x0] + (grid[y1][x1] - grid[y1][x0]) * fx
        return a + (b - a) * fy
    return sample


def puff(seed):
    """Альфа клуба: мягкий радиальный спад × fbm-шум; яркость чуть выше сверху (объём)."""
    octaves = [(value_noise(seed * 10 + i, 3 * 2 ** i), 0.5 ** i) for i in range(4)]
    norm = sum(w for _, w in octaves)
    rnd = random.Random(seed)
    cx, cy = 0.5 + rnd.uniform(-0.04, 0.04), 0.5 + rnd.uniform(-0.04, 0.04)
    px = []
    for j in range(CELL):
        for i in range(CELL):
            u, v = (i + 0.5) / CELL, (j + 0.5) / CELL
            n = sum(f(u, v) * w for f, w in octaves) / norm          # 0..1
            r = math.hypot(u - cx, v - cy) / 0.46
            r = r * (0.85 + 0.4 * (n - 0.5) * 2)                        # рваный край
            fall = max(0.0, 1 - r * r) ** 1.3                           # плотное тело, мягкий край
            a = min(1.0, fall * (0.75 + 0.5 * n))
            edge = min(u, v, 1 - u, 1 - v) / 0.1                         # гарантированно 0 у края ячейки
            a *= max(0.0, min(1.0, edge)) ** 2
            shade = 0.82 + 0.18 * (1 - v) + 0.1 * (n - 0.5)
            g = max(0, min(255, int(255 * shade)))
            px.append((g, g, g, max(0, min(255, int(255 * a)))))
    return px


def build_atlas():
    cells = [puff(s) for s in (11, 23, 37, 51)]
    img = [None] * (SIZE * SIZE)
    for q, cell in enumerate(cells):
        ox, oy = (q % 2) * CELL, (q // 2) * CELL
        for j in range(CELL):
            for i in range(CELL):
                img[(oy + j) * SIZE + ox + i] = cell[j * CELL + i]
    return img


def downsample(img, size):
    h = size // 2
    out = []
    for j in range(h):
        for i in range(h):
            acc = [0, 0, 0, 0]
            for dj in (0, 1):
                for di in (0, 1):
                    p = img[(2 * j + dj) * size + 2 * i + di]
                    for c in range(4):
                        acc[c] += p[c]
            out.append(tuple(a // 4 for a in acc))
    return out


def bgra(img):
    return b"".join(struct.pack("4B", p[2], p[1], p[0], p[3]) for p in img)


def write_vtf(path, img):
    mips = [(SIZE, img)]
    s, cur = SIZE, img
    while s > 1:
        cur = downsample(cur, s)
        s //= 2
        mips.append((s, cur))
    flags = 0x4 | 0x8 | 0x2000 | 0x200        # CLAMPS | CLAMPT | EIGHTBITALPHA | NOLOD
    header = struct.pack("<4s2IIHHIHH4x3f4xfIBiBBH",
                         b"VTF\0", 7, 2, 80, SIZE, SIZE, flags, 1, 0,
                         1.0, 1.0, 1.0, 1.0, 12, len(mips), -1, 0, 0, 1)
    assert len(header) == 65, len(header)
    header += b"\0" * (80 - len(header))
    data = b"".join(bgra(m) for _, m in reversed(mips))   # от меньшего к большему
    with open(path, "wb") as fh:
        fh.write(header + data)
    return len(mips)


VMT = '''"UnlitGeneric"
{
	"$basetexture"	"aether/smoke_puff"
	"$vertexcolor"	"1"
	"$vertexalpha"	"1"
	"$translucent"	"1"
	"$nocull"	"1"
}
'''

if __name__ == "__main__":
    out_dir = os.path.join(ADDON, "materials", "aether")
    os.makedirs(out_dir, exist_ok=True)
    n = write_vtf(os.path.join(out_dir, "smoke_puff.vtf"), build_atlas())
    with open(os.path.join(out_dir, "smoke_puff.vmt"), "w", encoding="ascii", newline="\n") as fh:
        fh.write(VMT)
    size = os.path.getsize(os.path.join(out_dir, "smoke_puff.vtf"))
    print(f"smoke_puff.vtf: {SIZE}x{SIZE}, mips={n}, {size} bytes")


# --- Атлас 4×4 для облаков (cl_mesher): 16 разных клубов 128×128, numpy ---------------------------------
def build_atlas16(size=512, seed=101):
    """Клуб = сумма 4–7 мягких «бугров» со смещениями (кучевая форма, не круг) × рваный край по fbm.
    Яркость — нейтральная: светлые выпуклости, темнее во впадинах между буграми (рельеф без направления;
    направление света задаёт меш: верх спрайта светлее, низ темнее — cl_mesher)."""
    import numpy as np
    cell = size // 4
    rnd = np.random.default_rng(seed)
    yy, xx = (np.mgrid[0:cell, 0:cell] + 0.5) / cell

    def fbm(n_oct, base):
        out = np.zeros((cell, cell))
        amp, tot = 1.0, 0.0
        for o in range(n_oct):
            f = base * 2 ** o
            g = rnd.random((f + 3, f + 3))
            xi, yi = xx * f, yy * f
            x0, y0 = xi.astype(int), yi.astype(int)
            fx, fy = xi - x0, yi - y0
            fx, fy = fx * fx * (3 - 2 * fx), fy * fy * (3 - 2 * fy)
            a = g[y0, x0] + (g[y0, x0 + 1] - g[y0, x0]) * fx
            b = g[y0 + 1, x0] + (g[y0 + 1, x0 + 1] - g[y0 + 1, x0]) * fx
            out += (a + (b - a) * fy) * amp
            tot += amp
            amp *= 0.5
        return out / tot

    img = np.zeros((size, size, 4))
    for q in range(16):
        # охват как у старого атласа (видимая часть до ~0.42 ячейки от центра): соседние спрайты перекрываются
        rr = np.sqrt((xx - 0.5) ** 2 + (yy - 0.5) ** 2) / 0.44
        body = np.clip(1 - rr * rr, 0, 1) ** 1.1                 # плотное тело всего клуба
        bumps = np.zeros((cell, cell))
        for _ in range(rnd.integers(7, 12)):           # бугры по краю и внутри — кучевой силуэт и рельеф
            ang, dist = rnd.uniform(0, 2 * np.pi), rnd.uniform(0.05, 0.3)
            cx, cy = 0.5 + np.cos(ang) * dist, 0.5 + np.sin(ang) * dist * 0.85
            r = rnd.uniform(0.1, 0.17)
            bumps = np.maximum(bumps, np.exp(-((xx - cx) ** 2 + (yy - cy) ** 2) / (2 * r * r)) * rnd.uniform(0.6, 1.0))
        n, n2 = fbm(5, 3), fbm(4, 7)
        dens = np.clip(np.maximum(body, bumps * 0.9) * (0.7 + 0.6 * n) - 0.1, 0, 1) / 0.9    # рваный край
        edge = np.clip(np.minimum.reduce([xx, yy, 1 - xx, 1 - yy]) / 0.08, 0, 1) ** 2
        alpha = np.clip(dens * 1.7, 0, 1) ** 1.1 * (0.85 + 0.15 * n2) * edge
        # рельеф без направления света: вершины бугров светлее, стыки между ними темнее
        lum = 0.7 + 0.3 * np.clip(bumps, 0, 1) ** 0.8 + 0.08 * (n2 - 0.5)
        ox, oy = (q % 4) * cell, (q // 4) * cell
        img[oy:oy + cell, ox:ox + cell, 0:3] = np.clip(lum, 0, 1)[..., None] * 255
        img[oy:oy + cell, ox:ox + cell, 3] = alpha * 255
    return img.astype(np.uint8)


def write_vtf_np(path, arr):
    """BGRA8888 VTF 7.2 с mip-цепочкой (усреднение 2×2, альфа-взвешенный цвет — без тёмной каймы)."""
    import numpy as np
    size = arr.shape[0]
    mips = [arr.astype(float)]
    while mips[-1].shape[0] > 1:
        m = mips[-1]
        a = m[..., 3:4]
        prem = np.concatenate([m[..., :3] * a, a], -1)
        prem = (prem[0::2, 0::2] + prem[1::2, 0::2] + prem[0::2, 1::2] + prem[1::2, 1::2]) / 4
        al = prem[..., 3:4]
        rgb = np.where(al > 0, prem[..., :3] / np.maximum(al, 1e-6), 255)
        mips.append(np.concatenate([rgb, al], -1))
    flags = 0x4 | 0x8 | 0x2000
    header = struct.pack("<4s2IIHHIHH4x3f4xfIBiBBH", b"VTF\0", 7, 2, 80, size, size, flags, 1, 0,
                         1.0, 1.0, 1.0, 1.0, 12, len(mips), -1, 0, 0, 1)
    header += b"\0" * (80 - len(header))
    data = b"".join(np.clip(m, 0, 255).astype(np.uint8)[..., [2, 1, 0, 3]].tobytes() for m in reversed(mips))
    with open(path, "wb") as fh:
        fh.write(header + data)


def main16():
    out_dir = os.path.join(ADDON, "materials", "aether")
    os.makedirs(out_dir, exist_ok=True)
    arr = build_atlas16()
    try:   # DXT5 через vtex из GMod (в 4 раза меньше); без vtex — несжатый BGRA
        import make_models as MM
        from PIL import Image
        MM.write_vtf_dxt("smoke_puff4", Image.fromarray(arr, "RGBA"))
    except Exception as e:   # noqa: BLE001 — запасной путь сборки
        print("vtex unavailable, writing uncompressed:", e)
        write_vtf_np(os.path.join(out_dir, "smoke_puff4.vtf"), arr)
    with open(os.path.join(out_dir, "smoke_puff4.vmt"), "w", encoding="ascii", newline="\n") as fh:
        fh.write(VMT.replace("aether/smoke_puff", "aether/smoke_puff4"))
    return arr


if __name__ == "__main__":
    a16 = main16()
    print("smoke_puff4.vtf: 512x512 (4x4)")
