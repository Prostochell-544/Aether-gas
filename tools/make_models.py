"""Процедурные модели Aether: геометрия → SMD → studiomdl, текстуры (Pillow) → TGA → vtex (DXT),
иконки спавнменю — программный растеризатор тех же мешей (numpy).

    python -I tools/make_models.py            # всё
    python -I tools/make_models.py --only grenade,canister

Результат кладётся прямо в аддон: models/aether/*, materials/models/aether/*, materials/entities/*.png.
Соглашения: Z вверх, «вперёд» +X; SMD v отсчитывается снизу (v_smd = 1 − v_картинки);
треугольники разворачиваются против часовой относительно внешней нормали (лицевая сторона Source).
"""
import argparse
import math
import os
import random
import shutil
import subprocess

import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

GMOD = os.environ.get("GMOD_DIR", r"C:\Program Files (x86)\Steam\steamapps\common\GarrysMod")
GAME = os.path.join(GMOD, "garrysmod")
_REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# клон репозитория (addon.json рядом с tools/) — пишем в него; иначе — в живой аддон в GMod
ADDON = os.environ.get("AETHER_ADDON") or (_REPO if os.path.exists(os.path.join(_REPO, "addon.json"))
                                           else os.path.join(GAME, "addons", "aether_gaslua"))
BUILD = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "build", "models")
FONTS = r"C:\Windows\Fonts"
# python -I не добавляет папку скрипта в sys.path — соседний texgen.py подключаем явно
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

GASES = {  # имя: (цвет краски, цвет полосы, надпись, подпись) — порядок = AetherGas.BaseGases (скины)
    "smoke":    ((150, 152, 156), (235, 235, 235), "SMOKE", "TACTICAL SCREEN"),
    "chlorine": ((196, 186, 52), (40, 40, 40), "CHLORINE", "Cl2  TOXIC GAS"),
    "methane":  ((70, 110, 170), (230, 70, 40), "METHANE", "CH4  FLAMMABLE"),
    "co_smoke": ((60, 58, 56), (220, 120, 30), "CO", "ASPHYXIANT"),
    "steam":    ((210, 214, 220), (60, 120, 200), "STEAM", "HOT VAPOUR"),
    "tear_gas": ((222, 222, 214), (200, 40, 36), "CS GAS", "TEAR GAS  IRRITANT"),
    "sarin":    ((82, 88, 62), (40, 150, 64), "GB SARIN", "NERVE AGENT"),
    "mustard":  ((82, 88, 62), (226, 196, 40), "HD", "BLISTER AGENT"),
    "h2s":      ((200, 182, 62), (200, 50, 36), "H2S", "TOXIC  FLAMMABLE"),
    "ammonia":  ((226, 204, 74), (50, 110, 196), "AMMONIA", "NH3  CORROSIVE"),
    "hydrogen": ((186, 38, 34), (240, 240, 240), "HYDROGEN", "H2  FLAMMABLE"),
    "nitrogen": ((38, 38, 42), (236, 236, 236), "LIQ. N2", "CRYOGENIC"),
    "co2":      ((140, 142, 146), (36, 36, 36), "CO2", "ASPHYXIANT"),
    "signal_red":    ((86, 92, 64), (214, 52, 44), "SIGNAL", "RED SMOKE"),
    "signal_green":  ((86, 92, 64), (60, 176, 72), "SIGNAL", "GREEN SMOKE"),
    "signal_yellow": ((86, 92, 64), (236, 206, 52), "SIGNAL", "YELLOW SMOKE"),
    "signal_violet": ((86, 92, 64), (140, 72, 196), "SIGNAL", "VIOLET SMOKE"),
    "signal_orange": ((86, 92, 64), (240, 128, 36), "SIGNAL", "ORANGE SMOKE"),
}
GAS_ORDER = list(GASES)
GAS_GLOW = {  # цвет облака на иконке
    "smoke": (200, 200, 210), "chlorine": (196, 206, 62), "methane": (90, 140, 230), "co_smoke": (90, 80, 70),
    "steam": (230, 235, 245), "tear_gas": (235, 230, 210), "sarin": (120, 200, 120), "mustard": (170, 140, 70),
    "h2s": (200, 205, 150), "ammonia": (200, 220, 240), "hydrogen": (230, 90, 80), "nitrogen": (200, 225, 250),
    "co2": (170, 175, 185), "signal_red": (214, 52, 44), "signal_green": (60, 176, 72),
    "signal_yellow": (236, 206, 52), "signal_violet": (140, 72, 196), "signal_orange": (240, 128, 36),
}


def font(name, size):
    try:
        return ImageFont.truetype(os.path.join(FONTS, name), size)
    except OSError:
        return ImageFont.load_default()


# =============================================================================================
# Геометрия
# =============================================================================================
def rot_z_to(axis):
    """Матрица поворота, переводящая +Z в направление axis."""
    a = np.array(axis, float)
    a /= np.linalg.norm(a)
    z = np.array([0.0, 0.0, 1.0])
    v = np.cross(z, a)
    c = float(np.dot(z, a))
    if np.linalg.norm(v) < 1e-9:
        return np.eye(3) if c > 0 else np.diag([1.0, -1.0, -1.0])
    vx = np.array([[0, -v[2], v[1]], [v[2], 0, -v[0]], [-v[1], v[0], 0]])
    return np.eye(3) + vx + vx @ vx * (1 / (1 + c))


def rot_axis(axis, ang):
    a = np.array(axis, float)
    a /= np.linalg.norm(a)
    x, y, z = a
    c, s = math.cos(ang), math.sin(ang)
    C = 1 - c
    return np.array([[c + x * x * C, x * y * C - z * s, x * z * C + y * s],
                     [y * x * C + z * s, c + y * y * C, y * z * C - x * s],
                     [z * x * C - y * s, z * y * C + x * s, c + z * z * C]])


class Mesh:
    def __init__(self):
        self.tris = []   # (material, bone, [(p, n, uv)]*3)

    def tri(self, mat, bone, a, b, c):
        pa, pb, pc = (np.array(v[0], float) for v in (a, b, c))
        n = np.array(a[1], float) + np.array(b[1], float) + np.array(c[1], float)
        if np.dot(np.cross(pb - pa, pc - pa), n) < 0:
            b, c = c, b
        self.tris.append((mat, bone, [a, b, c]))

    def quad(self, mat, bone, a, b, c, d):
        self.tri(mat, bone, a, b, c)
        self.tri(mat, bone, a, c, d)

    def extend(self, other, M=np.eye(3), t=(0, 0, 0)):
        t = np.array(t, float)
        for mat, bone, vs in other.tris:
            self.tris.append((mat, bone, [(M @ np.array(p) + t, M @ np.array(n), uv) for p, n, uv in vs]))


def uvmap(rect, u, v):
    u0, v0, u1, v1 = rect
    return (u0 + (u1 - u0) * u, v0 + (v1 - v0) * v)


TEX_PX = 512   # стороны атласов (для равномерной плотности текселей)


def fit_uv(rect, len_u, len_v):
    """Доли региона по u и v для поверхности len_u × len_v без растяжения: одна из сторон — 1,
    другая — меньше (кусок региона, а не весь регион, натянутый на тонкую грань)."""
    wu, wv = (rect[2] - rect[0]) * TEX_PX, (rect[3] - rect[1]) * TEX_PX
    k = min(wu / max(len_u, 1e-6), wv / max(len_v, 1e-6))
    return min(1.0, len_u * k / wu), min(1.0, len_v * k / wv)


def cylinder(mat, rect, r, h, seg=24, base=(0, 0, 0), axis=(0, 0, 1), r_top=None, caps=True,
             cap_rect=None, bone=0, inside=False, fit=True):
    """fit=True — текстура без растяжения (для шумовых материалов); fit=False — регион целиком
    по окружности и высоте (корпуса с надписями)."""
    m = Mesh()
    r_top = r if r_top is None else r_top
    slope = (r - r_top) / h if h else 0
    su, sv = fit_uv(rect, 2 * math.pi * max(r, r_top), h) if fit else (1.0, 1.0)
    for i in range(seg):
        a0, a1 = 2 * math.pi * i / seg, 2 * math.pi * (i + 1) / seg
        pts = []
        for a, uu in ((a0, su * i / seg), (a1, su * (i + 1) / seg)):
            c, s = math.cos(a), math.sin(a)
            n = np.array([c, s, slope])
            n /= np.linalg.norm(n)
            if inside:
                n = -n
            pts.append(((r * c, r * s, 0), (r_top * c, r_top * s, h), tuple(n), uu))
        (b0, t0, n0, u0), (b1, t1, n1, u1) = pts
        m.quad(mat, bone, (b0, n0, uvmap(rect, u0, sv)), (b1, n1, uvmap(rect, u1, sv)),
               (t1, n1, uvmap(rect, u1, 0)), (t0, n0, uvmap(rect, u0, 0)))
    if caps:
        cr = cap_rect or rect
        for z, rr, nz in ((0, r, -1), (h, r_top, 1)):
            for i in range(seg):
                a0, a1 = 2 * math.pi * i / seg, 2 * math.pi * (i + 1) / seg
                p0 = (rr * math.cos(a0), rr * math.sin(a0), z)
                p1 = (rr * math.cos(a1), rr * math.sin(a1), z)
                uv = lambda p: uvmap(cr, 0.5 + p[0] / (2 * rr), 0.5 + p[1] / (2 * rr))
                n = (0, 0, nz)
                m.tri(mat, bone, ((0, 0, z), n, uvmap(cr, 0.5, 0.5)), (p0, n, uv(p0)), (p1, n, uv(p1)))
    out = Mesh()
    out.extend(m, rot_z_to(axis), base)
    return out


def ellipsoid(mat, rect, radii, center=(0, 0, 0), seg=24, rings=12, part=None, bone=0, axis=(0, 0, 1)):
    """part: None — целиком, 'top'/'bottom' — по Z, 'front' — x ≥ 0 (после поворота axis)."""
    m = Mesh()
    rx, ry, rz = radii
    th0, th1 = 0.0, math.pi
    if part == "top":
        th1 = math.pi / 2
    elif part == "bottom":
        th0 = math.pi / 2
    ph0, ph1 = 0.0, 2 * math.pi
    if part == "front":
        ph0, ph1 = -math.pi / 2, math.pi / 2

    def pt(th, ph):
        sx, sy, sz = math.sin(th) * math.cos(ph), math.sin(th) * math.sin(ph), math.cos(th)
        n = np.array([sx / rx, sy / ry, sz / rz])
        return (rx * sx, ry * sy, rz * sz), tuple(n / np.linalg.norm(n))

    for j in range(rings):
        t0 = th0 + (th1 - th0) * j / rings
        t1 = th0 + (th1 - th0) * (j + 1) / rings
        for i in range(seg):
            p0 = ph0 + (ph1 - ph0) * i / seg
            p1 = ph0 + (ph1 - ph0) * (i + 1) / seg
            verts = []
            for th, ph, uu, vv in ((t0, p0, i / seg, j / rings), (t0, p1, (i + 1) / seg, j / rings),
                                   (t1, p1, (i + 1) / seg, (j + 1) / rings), (t1, p0, i / seg, (j + 1) / rings)):
                p, n = pt(th, ph)
                verts.append((p, n, uvmap(rect, uu, vv)))
            if j == 0 and part != "bottom" and th0 == 0:
                m.tri(mat, bone, verts[0], verts[2], verts[3])
            else:
                m.quad(mat, bone, *verts)
    out = Mesh()
    out.extend(m, rot_z_to(axis), center)
    return out


def torus(mat, rect, R, r, center=(0, 0, 0), axis=(0, 0, 1), seg=24, side=8, bone=0):
    m = Mesh()
    su, sv = fit_uv(rect, 2 * math.pi * R, 2 * math.pi * r)
    for i in range(seg):
        for j in range(side):
            vs = []
            for di, dj in ((0, 0), (1, 0), (1, 1), (0, 1)):
                a = 2 * math.pi * (i + di) / seg
                b = 2 * math.pi * (j + dj) / side
                n = (math.cos(a) * math.cos(b), math.sin(a) * math.cos(b), math.sin(b))
                p = ((R + r * math.cos(b)) * math.cos(a), (R + r * math.cos(b)) * math.sin(a), r * math.sin(b))
                vs.append((p, n, uvmap(rect, su * (i + di) / seg, sv * (j + dj) / side)))
            m.quad(mat, bone, *vs)
    out = Mesh()
    out.extend(m, rot_z_to(axis), center)
    return out


def box(mat, rect, mins, maxs, bone=0, M=np.eye(3), t=(0, 0, 0), fit=True):
    """fit=True — одна плотность текселей на все грани (масштаб по наибольшему ребру, грань берёт свой
    кусок региона, тонкие грани не растягивают весь регион); fit=False — регион целиком на каждую грань
    (таблички с надписью)."""
    m = Mesh()
    x0, y0, z0 = mins
    x1, y1, z1 = maxs
    dx, dy, dz = x1 - x0, y1 - y0, z1 - z0
    faces = [
        ((1, 0, 0), [(x1, y0, z0), (x1, y1, z0), (x1, y1, z1), (x1, y0, z1)], dy, dz),
        ((-1, 0, 0), [(x0, y1, z0), (x0, y0, z0), (x0, y0, z1), (x0, y1, z1)], dy, dz),
        ((0, 1, 0), [(x1, y1, z0), (x0, y1, z0), (x0, y1, z1), (x1, y1, z1)], dx, dz),
        ((0, -1, 0), [(x0, y0, z0), (x1, y0, z0), (x1, y0, z1), (x0, y0, z1)], dx, dz),
        ((0, 0, 1), [(x0, y0, z1), (x1, y0, z1), (x1, y1, z1), (x0, y1, z1)], dx, dy),
        ((0, 0, -1), [(x0, y1, z0), (x1, y1, z0), (x1, y0, z0), (x0, y0, z0)], dx, dy),
    ]
    big = max(dx, dy, dz, 1e-6)
    wu, wv = rect[2] - rect[0], rect[3] - rect[1]
    for n, q, lu, lv in faces:
        if fit:   # квадратные тексели: доля региона = длина грани / наибольшее ребро (с учётом формы региона)
            k = min(wu, wv)
            su, sv = min(1.0, lu / big * k / wu), min(1.0, lv / big * k / wv)
        else:
            su, sv = 1.0, 1.0
        uvs = [(0, sv), (su, sv), (su, 0), (0, 0)]
        m.quad(mat, bone, *[(p, n, uvmap(rect, *uv)) for p, uv in zip(q, uvs)])
    out = Mesh()
    out.extend(m, M, t)
    return out



def param_surface(mat, rect, f, u0, u1, v0, v1, nu, nv, center=(0, 0, 0), bone=0):
    """Поверхность p = f(u, v). Нормали — по конечным разностям, наружу от center."""
    m = Mesh()
    c = np.array(center, float)
    eps = 1e-4

    def pn(u, v):
        p = np.array(f(u, v), float)
        du = np.array(f(u + eps, v), float) - np.array(f(u - eps, v), float)
        dv = np.array(f(u, v + eps), float) - np.array(f(u, v - eps), float)
        n = np.cross(du, dv)
        if np.linalg.norm(n) < 1e-12:
            n = p - c
        n /= np.linalg.norm(n) + 1e-12
        if np.dot(n, p - c) < 0:
            n = -n
        return p, n

    for i in range(nu):
        for j in range(nv):
            vs = []
            for di, dj in ((0, 0), (1, 0), (1, 1), (0, 1)):
                u = u0 + (u1 - u0) * (i + di) / nu
                v = v0 + (v1 - v0) * (j + dj) / nv
                p, n = pn(u, v)
                vs.append((tuple(p), tuple(n), uvmap(rect, (i + di) / nu, (j + dj) / nv)))
            m.quad(mat, bone, *vs)
    return m


def ribbon(mat, rect, path, normals, width, bone=0):
    """Плоский ремень вдоль полилинии path: ширина width поперёк (касательная × нормаль поверхности),
    двусторонний. u — вдоль ремня (без растяжения), v — поперёк."""
    m = Mesh()
    P = [np.array(p, float) for p in path]
    N = [np.array(n, float) / np.linalg.norm(n) for n in normals]
    L = sum(np.linalg.norm(P[i + 1] - P[i]) for i in range(len(P) - 1))
    su, sv = fit_uv(rect, L, width)
    acc = 0.0
    edges = []
    for i, p in enumerate(P):
        tng = P[min(i + 1, len(P) - 1)] - P[max(i - 1, 0)]
        tng /= np.linalg.norm(tng) + 1e-9
        side = np.cross(tng, N[i])
        side /= np.linalg.norm(side) + 1e-9
        if i > 0:
            acc += np.linalg.norm(P[i] - P[i - 1])
        edges.append((p - side * width / 2, p + side * width / 2, N[i], acc / max(L, 1e-6) * su))
    for i in range(len(edges) - 1):
        a0, a1, n0, u0 = edges[i]
        b0, b1, n1, u1 = edges[i + 1]
        m.quad(mat, bone, (tuple(a0), tuple(n0), uvmap(rect, u0, 0)), (tuple(b0), tuple(n1), uvmap(rect, u1, 0)),
               (tuple(b1), tuple(n1), uvmap(rect, u1, sv)), (tuple(a1), tuple(n0), uvmap(rect, u0, sv)))
    return double_sided(m)


def tube(mat, rect, path, r, side=6, bone=0):
    """Трубка радиуса r вдоль полилинии (кант, шланг)."""
    m = Mesh()
    P = [np.array(p, float) for p in path]
    L = sum(np.linalg.norm(P[i + 1] - P[i]) for i in range(len(P) - 1))
    su, sv = fit_uv(rect, L, 2 * math.pi * r)
    rings, acc = [], 0.0
    ref = np.array([0.0, 0.0, 1.0])
    for i, p in enumerate(P):
        tng = P[min(i + 1, len(P) - 1)] - P[max(i - 1, 0)]
        tng /= np.linalg.norm(tng) + 1e-9
        if abs(np.dot(tng, ref)) > 0.9:
            ref = np.array([1.0, 0.0, 0.0])
        b1 = np.cross(tng, ref); b1 /= np.linalg.norm(b1)
        b2 = np.cross(tng, b1)
        if i > 0:
            acc += np.linalg.norm(P[i] - P[i - 1])
        ring = []
        for j in range(side + 1):
            a = 2 * math.pi * j / side
            n = b1 * math.cos(a) + b2 * math.sin(a)
            ring.append((p + n * r, n, acc / max(L, 1e-6) * su, j / side * sv))
        rings.append(ring)
    for i in range(len(rings) - 1):
        for j in range(side):
            vs = []
            for ii, jj in ((i, j), (i + 1, j), (i + 1, j + 1), (i, j + 1)):
                p, n, u, v = rings[ii][jj]
                vs.append((tuple(p), tuple(n), uvmap(rect, u, v)))
            m.quad(mat, bone, *vs)
    return m


def torus_arc(mat, rect, R, r, a0, a1, center=(0, 0, 0), axis=(0, 0, 1), seg=16, side=6, bone=0, M2=None):
    m = Mesh()
    for i in range(seg):
        for j in range(side):
            vs = []
            for di, dj in ((0, 0), (1, 0), (1, 1), (0, 1)):
                a = a0 + (a1 - a0) * (i + di) / seg
                b = 2 * math.pi * (j + dj) / side
                n = (math.cos(a) * math.cos(b), math.sin(a) * math.cos(b), math.sin(b))
                p = ((R + r * math.cos(b)) * math.cos(a), (R + r * math.cos(b)) * math.sin(a), r * math.sin(b))
                vs.append((p, n, uvmap(rect, (i + di) / seg, (j + dj) / side)))
            m.quad(mat, bone, *vs)
    out = Mesh()
    out.extend(m, rot_z_to(axis) if M2 is None else M2, center)
    return out


def double_sided(mesh):
    out = Mesh()
    out.tris = list(mesh.tris)
    for mat, bone, vs in mesh.tris:
        out.tris.append((mat, bone, [(p, tuple(-np.array(n)), uv) for p, n, uv in reversed(vs)]))
    return out


def combine(*meshes):
    out = Mesh()
    for m in meshes:
        out.tris.extend(m.tris)
    return out


# =============================================================================================
# SMD / QC
# =============================================================================================
# studiomdl поворачивает модель на +90° вокруг Z (в игре SMD +X становится +Y — экран анализатора
# смотрел вбок, воздуходувка дула вбок, решётка вставала поперёк). Компенсируем: геометрию и корневую
# кость поворачиваем на −90°, тогда «вперёд» модели (+X в этом скрипте) = ent:GetForward() в игре.
def _rz_m90(v):
    return (v[1], -v[0], v[2])


def write_smd(path, mesh, bones):
    with open(path, "w", newline="\n") as f:
        f.write("version 1\nnodes\n")
        for i, (name, parent, _) in enumerate(bones):
            f.write(f'{i} "{name}" {parent}\n')
        f.write("end\nskeleton\ntime 0\n")
        for i, (_, parent, pos) in enumerate(bones):
            if parent < 0:   # корень: позиция в повёрнутом пространстве, поворот −90° по Z
                q = _rz_m90(pos)
                f.write(f"{i} {q[0]:.4f} {q[1]:.4f} {q[2]:.4f} 0 0 {-math.pi / 2:.6f}\n")
            else:            # потомок: смещение в системе родителя (поворот уже унаследован)
                f.write(f"{i} {pos[0]:.4f} {pos[1]:.4f} {pos[2]:.4f} 0 0 0\n")
        f.write("end\ntriangles\n")
        for mat, bone, vs in mesh.tris:
            f.write(mat + "\n")
            for p, n, (u, v) in vs:
                p, n = _rz_m90(p), _rz_m90(n)
                f.write(f"{bone} {p[0]:.4f} {p[1]:.4f} {p[2]:.4f} {n[0]:.4f} {n[1]:.4f} {n[2]:.4f} {u:.5f} {1 - v:.5f}\n")
        f.write("end\n")


def write_qc(path, name, ref, phys, mass, surface, skins=None):
    lines = [f'$modelname "aether/{name}.mdl"', '$cdmaterials "models/aether/"',
             f'$surfaceprop "{surface}"', f'$body body "{ref}"', f'$sequence idle "{ref}" fps 1']
    if skins:
        lines.append("$texturegroup skinfamilies\n{")
        for s in skins:
            lines.append('\t{ "' + s + '" }')
        lines.append("}")
    lines.append(f'$collisionmodel "{phys}" {{ $mass {mass} $inertia 1 $damping 0 $rotdamping 0 }}')
    with open(path, "w", newline="\n") as f:
        f.write("\n".join(lines) + "\n")


def compile_model(qc):
    r = subprocess.run([os.path.join(GMOD, "bin", "studiomdl.exe"), "-game", GAME, "-nop4", qc],
                       capture_output=True, text=True, timeout=300)
    if "Completed" not in r.stdout:
        raise RuntimeError(f"studiomdl failed for {qc}:\n{r.stdout[-3000:]}\n{r.stderr[-2000:]}")


# =============================================================================================
# Текстуры
# =============================================================================================
def noise_img(size, base, amount=18, seed=0, blur=1.2):
    rnd = np.random.default_rng(seed)
    n = rnd.normal(0, amount, (size[1], size[0], 1))
    arr = np.clip(np.array(base, float)[None, None, :] + n, 0, 255).astype(np.uint8)
    return Image.fromarray(arr, "RGB").filter(ImageFilter.GaussianBlur(blur))


def wear(img, seed, scratches=60, color=(200, 200, 200)):
    d = ImageDraw.Draw(img)
    rnd = random.Random(seed)
    w, h = img.size
    for _ in range(scratches):
        x, y = rnd.uniform(0, w), rnd.uniform(0, h)
        L = rnd.uniform(4, 30)
        a = rnd.uniform(0, math.pi)
        c = tuple(int(cc * rnd.uniform(0.7, 1.0)) for cc in color)
        d.line([(x, y), (x + L * math.cos(a), y + L * math.sin(a))], fill=c, width=1)
    return img


def metal(size, base=(140, 142, 146), seed=1):
    img = noise_img(size, base, 10, seed, 0.6)
    arr = np.array(img).astype(float)
    arr += np.linspace(-12, 12, size[0])[None, :, None]           # «шлифовка»
    return Image.fromarray(np.clip(arr, 0, 255).astype(np.uint8))


def text_centered(d, box, text, fnt, fill, stroke=0, stroke_fill=None):
    x0, y0, x1, y1 = box
    bb = d.textbbox((0, 0), text, font=fnt, stroke_width=stroke)
    w, h = bb[2] - bb[0], bb[3] - bb[1]
    d.text(((x0 + x1 - w) / 2 - bb[0], (y0 + y1 - h) / 2 - bb[1]), text, font=fnt, fill=fill,
           stroke_width=stroke, stroke_fill=stroke_fill)


def hazard_diamond(img, cx, cy, size, color, symbol):
    d = ImageDraw.Draw(img)
    pts = [(cx, cy - size), (cx + size, cy), (cx, cy + size), (cx - size, cy)]
    d.polygon(pts, fill=(245, 245, 240), outline=(20, 20, 20))
    inner = [(cx, cy - size * 0.86), (cx + size * 0.86, cy), (cx, cy + size * 0.86), (cx - size * 0.86, cy)]
    d.polygon(inner, outline=color, width=max(2, int(size * 0.08)))
    text_centered(d, (cx - size, cy - size * 0.6, cx + size, cy + size * 0.6), symbol, font("impact.ttf", int(size * 0.7)), (20, 20, 20))


def stripes(img, box, colors=((235, 190, 30), (25, 25, 25)), width=18):
    d = ImageDraw.Draw(img)
    x0, y0, x1, y1 = box
    k = 0
    for x in range(int(x0) - int(y1 - y0), int(x1), width):
        d.polygon([(x, y1), (x + width, y1), (x + width + (y1 - y0), y0), (x + (y1 - y0), y0)], fill=colors[k % 2])
        k += 1
    # обрезка выходящих за прямоугольник полос — перекрасить поля исходным фоном не нужно: полосы рисуются в своём регионе


def paste_region(dst, src, rect):
    W, H = dst.size
    x0, y0, x1, y1 = int(rect[0] * W), int(rect[1] * H), int(rect[2] * W), int(rect[3] * H)
    dst.paste(src.resize((x1 - x0, y1 - y0), Image.LANCZOS), (x0, y0))



# --- Маркировка опасности: NFPA 704, пиктограммы GHS, оранжевая табличка ООН --------------------
HAZARD = {  # газ: (здоровье, горючесть, нестабильность, особое, [GHS], номер ООН)
    "smoke":    (2, 1, 0, "", ["excl"], ""),
    "chlorine": (4, 0, 0, "OX", ["skull", "oxid", "cyl"], "1017"),
    "methane":  (2, 4, 0, "", ["flame", "cyl"], "1971"),
    "co_smoke": (3, 4, 0, "", ["skull", "flame", "cyl"], "1016"),
    "steam":    (2, 0, 0, "", ["excl"], ""),
    "propane":  (2, 4, 0, "", ["flame", "cyl"], "1978"),
    "tear_gas": (2, 1, 0, "", ["excl"], "1700"),
    "sarin":    (4, 1, 1, "", ["skull"], "2810"),
    "mustard":  (4, 1, 1, "", ["skull", "corr"], "2810"),
    "h2s":      (4, 4, 0, "", ["skull", "flame", "cyl"], "1053"),
    "ammonia":  (3, 1, 0, "", ["skull", "corr", "cyl"], "1005"),
    "hydrogen": (0, 4, 0, "", ["flame", "cyl"], "1049"),
    "nitrogen": (3, 0, 0, "SA", ["cyl"], "1977"),
    "co2":      (2, 0, 0, "SA", ["cyl"], "1013"),
    "signal_red":    (1, 1, 0, "", ["excl"], "0507"),
    "signal_green":  (1, 1, 0, "", ["excl"], "0507"),
    "signal_yellow": (1, 1, 0, "", ["excl"], "0507"),
    "signal_violet": (1, 1, 0, "", ["excl"], "0507"),
    "signal_orange": (1, 1, 0, "", ["excl"], "0507"),
}


def nfpa_diamond(img, cx, cy, size, health, flam, inst, special):
    d = ImageDraw.Draw(img)
    h = size / 2
    quads = [((cx, cy - size), (0, -1), (230, 40, 40), str(flam)),     # верх — горючесть
             ((cx - h, cy - h), (-1, 0), (30, 90, 200), str(health)),  # слева — здоровье
             ((cx + h, cy - h), (1, 0), (240, 215, 30), str(inst)),    # справа — нестабильность
             ((cx, cy), (0, 1), (250, 250, 250), special)]             # низ — особое
    fnt = font("arialbd.ttf", int(size * 0.42))
    for (tx, ty), _, col, label in quads:
        pts = [(tx, ty), (tx + h, ty + h), (tx, ty + size), (tx - h, ty + h)]
        d.polygon(pts, fill=col, outline=(15, 15, 15))
        if label:
            text_centered(d, (tx - h, ty + h * 0.35, tx + h, ty + size - h * 0.35), label, fnt,
                          (15, 15, 15) if col != (30, 90, 200) else (250, 250, 250))
    d.polygon([(cx, cy - size), (cx + size, cy), (cx, cy + size), (cx - size, cy)], outline=(10, 10, 10), width=3)


def ghs_pictogram(img, cx, cy, size, kind):
    d = ImageDraw.Draw(img)
    pts = [(cx, cy - size), (cx + size, cy), (cx, cy + size), (cx - size, cy)]
    d.polygon(pts, fill=(250, 250, 250))
    d.line(pts + [pts[0]], fill=(220, 20, 20), width=max(3, int(size * 0.13)), joint="curve")
    k = size * 0.45
    ink = (10, 10, 10)
    if kind == "skull":
        d.ellipse([cx - k * 0.7, cy - k * 0.9, cx + k * 0.7, cy + k * 0.35], fill=ink)
        d.rectangle([cx - k * 0.4, cy + k * 0.2, cx + k * 0.4, cy + k * 0.6], fill=ink)
        for sx in (-1, 1):
            d.ellipse([cx + sx * k * 0.3 - k * 0.2, cy - k * 0.45, cx + sx * k * 0.3 + k * 0.2, cy - k * 0.05], fill=(250, 250, 250))
        d.line([(cx - k, cy + k * 0.9), (cx + k, cy + k * 0.6)], fill=ink, width=max(2, int(k * 0.18)))
        d.line([(cx - k, cy + k * 0.6), (cx + k, cy + k * 0.9)], fill=ink, width=max(2, int(k * 0.18)))
    elif kind in ("flame", "oxid"):
        if kind == "oxid":
            d.ellipse([cx - k * 0.6, cy + k * 0.15, cx + k * 0.6, cy + k * 0.95], outline=ink, width=max(2, int(k * 0.2)))
        top = cy - k * (1.0 if kind == "flame" else 0.9)
        d.polygon([(cx, top), (cx + k * 0.55, cy - k * 0.1), (cx + k * 0.4, cy + k * (0.75 if kind == "flame" else 0.15)),
                   (cx - k * 0.45, cy + k * (0.75 if kind == "flame" else 0.15)), (cx - k * 0.55, cy - k * 0.05), (cx - k * 0.15, cy - k * 0.35)], fill=ink)
        if kind == "flame":
            d.rectangle([cx - k * 0.75, cy + k * 0.8, cx + k * 0.75, cy + k * 0.95], fill=ink)
    elif kind == "cyl":
        d.rounded_rectangle([cx - k * 0.95, cy - k * 0.3, cx + k * 0.75, cy + k * 0.3], int(k * 0.3), fill=ink)
        d.rectangle([cx + k * 0.75, cy - k * 0.12, cx + k * 1.0, cy + k * 0.12], fill=ink)
    elif kind == "corr":   # коррозия: две пробирки льют на брусок и на руку
        for sx in (-1, 1):
            x = cx + sx * k * 0.45
            d.polygon([(x - k * 0.18, cy - k * 0.95), (x + k * 0.18, cy - k * 0.95), (x + k * 0.18, cy - k * 0.45),
                       (x - k * 0.05, cy - k * 0.3), (x - k * 0.18, cy - k * 0.45)], fill=ink)
            for j in range(3):
                d.ellipse([x - k * 0.07, cy - k * 0.2 + j * k * 0.22, x + k * 0.07, cy - k * 0.06 + j * k * 0.22], fill=ink)
        d.rectangle([cx - k * 0.95, cy + k * 0.62, cx - k * 0.05, cy + k * 0.86], fill=ink)
        d.polygon([(cx + k * 0.1, cy + k * 0.86), (cx + k * 0.95, cy + k * 0.86), (cx + k * 0.95, cy + k * 0.55),
                   (cx + k * 0.35, cy + k * 0.6)], fill=ink)
    elif kind == "excl":
        d.rectangle([cx - k * 0.13, cy - k * 0.85, cx + k * 0.13, cy + k * 0.35], fill=ink)
        d.ellipse([cx - k * 0.16, cy + k * 0.55, cx + k * 0.16, cy + k * 0.87], fill=ink)


def un_plate(img, cx, cy, w, number):
    if not number:
        return
    d = ImageDraw.Draw(img)
    h = w * 0.55
    d.rectangle([cx - w / 2, cy - h / 2, cx + w / 2, cy + h / 2], fill=(240, 130, 20), outline=(10, 10, 10), width=3)
    text_centered(d, (cx - w / 2, cy - h / 2, cx + w / 2, cy + h / 2), number, font("arialbd.ttf", int(h * 0.62)), (10, 10, 10))


def hazard_panel(img, gas, x, y, scale=1.0):
    """Столбик маркировки: ромб NFPA, под ним пиктограммы GHS, ниже табличка ООН."""
    hlt, flm, ins, spc, ghs, un = HAZARD[gas]
    nfpa_diamond(img, x, y + 46 * scale, 44 * scale, hlt, flm, ins, spc)
    yy = y + 140 * scale
    for kind in ghs:
        ghs_pictogram(img, x, yy, 30 * scale, kind)
        yy += 64 * scale
    un_plate(img, x, yy + 6 * scale, 70 * scale, un)


def face_front(img):
    """Сдвиг окраски на четверть оборота: надписи, нарисованные на u = 0.25/0.75, встают на u = 0/0.5 —
    лицевую (+X) и тыльную стороны модели, а не на стык."""
    return Image.fromarray(np.roll(np.array(img), -img.size[0] // 4, axis=1))


# Регионы атласа (u0, v0, u1, v1) — v сверху вниз
R_BODY = (0, 0, 1, 0.625)
R_METAL = (0, 0.625, 0.5, 1)
R_CAP = (0.5, 0.625, 1, 1)


FLARE_ORDER = ["signal_red", "signal_green", "signal_yellow", "signal_violet", "signal_orange"]   # = скины фаера


FLARE_RU = {"signal_red": "КРАСНЫЙ", "signal_green": "ЗЕЛЁНЫЙ", "signal_yellow": "ЖЁЛТЫЙ",
            "signal_violet": "ФИОЛЕТОВЫЙ", "signal_orange": "ОРАНЖЕВЫЙ"}


def tex_flare(gas):
    """Ручной дымовой сигнал (по мотивам советских РДС): крафтовая картонная гильза с потёртостями и пятнами,
    бумажные полосы цвета дыма у головки и у дна, чёрный штамп вдоль гильзы, тёмная зажигательная головка,
    рифлёный колпачок-тёрка цвета дыма. Возвращает (цвет, нормали+блеск).
    Надпись идёт вдоль тонкой гильзы: рисуем в транспонированных координатах (строки — окружность 4.7 ед.
    на 512 пикс, столбцы — длина 8.6 ед. на 320 пикс), высоту букв растягиваем на отношение плотностей."""
    import texgen as T
    col = GAS_GLOW[gas]
    s = 141   # износ одинаковый у всех цветов — общая карта нормалей совпадает с цветом
    sq = (8.6 / 320) / (2 * math.pi * 0.75 / 512)      # ≈ 2.9: строк на единицу длины больше, чем столбцов
    tube = T.weathered_paint(320, 512, (176, 146, 100), s, wear=0.5, rims=("left", "right"), rim_width=14, hits=3,
                             rust=0.0, grime=1.3, fade=1.0, gloss_paint=0.06, primer=(140, 116, 80),
                             base_metal=(120, 98, 66))
    for c0, c1 in ((6, 40), (292, 304)):               # цветные бумажные полосы: у головки (сверху) и у дна
        a = np.zeros((512, 320))
        a[:, c0:c1] = 1
        a *= (1 - tube["chips"] * 0.8)
        tube["rgb"] = tube["rgb"] * (1 - a[..., None]) + np.array(col, float) * 0.92 * a[..., None]
    ink = (28, 26, 24)
    word = FLARE_RU[gas]
    for cy in (128, 384):                              # штамп на двух сторонах гильзы
        T.stencil_text(tube, "ДЫМ " + word, T.fit_font("ДЫМ " + word, 236, 26, "Bold Condensed"), (166, cy - 30),
                       ink, seed=s + cy, squash=sq, bridges=False, alpha=0.9)
        T.stencil_text(tube, "РДС-2   ЗАЖИГАТЬ ОТ СЕБЯ", T.fit_font("РДС-2   ЗАЖИГАТЬ ОТ СЕБЯ", 236, 13, "SemiBold Condensed"),
                       (166, cy + 14), ink, seed=s + cy + 1, squash=sq, bridges=False, alpha=0.8)
        T.stencil_text(tube, "ПАРТ. 4  1986", T.fit_font("ПАРТ. 4  1986", 120, 11, "SemiBold Condensed"),
                       (166, cy + 40), ink, seed=s + cy + 2, squash=sq, bridges=False, alpha=0.7)
    tube = {k: (tube[k].transpose(1, 0, 2) if k == "rgb" else tube[k].T)[::-1] for k in ("rgb", "height", "gloss")}
    tube = {k: np.roll(v, -128, axis=1) for k, v in tube.items()}   # штамп — на лицевую (+X) и тыльную стороны
    head = T.weathered_paint(256, 192, (46, 40, 36), s + 10, wear=0, hits=0, rust=0, grime=0.4, gloss_paint=0.1)
    head["height"] = head["height"] + T.fbm(256, 192, s + 11, ((3, 1),)) * 0.05     # шероховатая масса
    cap = T.weathered_paint(256, 192, tuple(int(c * 0.8) for c in col), s + 20, wear=0.6, hits=2, rust=0,
                            grime=0.8, gloss_paint=0.3, primer=(60, 58, 54))
    for y in range(0, 192, 8):                         # рифление колпачка
        cap["rgb"][y:y + 3] *= 0.75
        cap["height"][y:y + 3] -= 0.1
    color, nrm = Image.new("RGB", (512, 512)), Image.new("RGBA", (512, 512))
    for layer, rect in ((tube, R_BODY), (head, R_METAL), (cap, R_CAP)):
        paste_region(color, T.to_image(layer), rect)
        paste_region(nrm, T.normal_image(layer["height"], layer["gloss"], 4), rect)
    return color, nrm


def textures_flare():
    """Скины фаера: СССР, НАТО, классика × 5 цветов. Карта нормалей — одна на вид (рельеф без надписей одинаков)."""
    out = {}
    for i, g in enumerate(FLARE_ORDER):
        col, nrm = tex_flare(g)
        if i == 0:
            save_normal("flare_n", nrm)
        out[f"flare_{g}"] = (col, phong_vmt("flare_n"))
    for i, g in enumerate(FLARE_ORDER):
        col, nrm = tex_flare_nato(g)
        if i == 0:
            save_normal("flare_nato_n", nrm)
        out[f"flare_nato_{g}"] = (col, phong_vmt("flare_nato_n"))
    for g in FLARE_ORDER:
        out[f"flare_classic_{g}"] = tex_flare_classic(g)
    return out


def tex_flare_classic(gas):
    """Классический вид (до 0.12)."""
    """Сигнальный фаер: картонная гильза цвета дыма, надпись вдоль гильзы (тонкий цилиндр: по окружности
    тексели в ~3 раза уже, чем по длине, — надпись рисуется с поправкой и не сплющивается), белое кольцо
    у головки, тёмная зажигательная головка, пластиковый колпачок того же цвета."""
    col = GAS_GLOW[gas]
    S, H = 512, 320
    img = Image.new("RGB", (S, S))
    body = noise_img((S, H), tuple(int(c * 0.9) for c in col), 7, 141)
    d = ImageDraw.Draw(body)
    d.rectangle([0, 18, S, 40], fill=(236, 236, 230))
    d.rectangle([0, 286, S, 298], fill=(30, 30, 30))
    ink = (20, 20, 20) if sum(col) > 420 else (245, 245, 240)
    # растяжение по длине: окружность 2π·0.75 на S пикселей, длина 8.6 на H пикселей
    stretch = (8.6 / H) / (2 * math.pi * 0.75 / S)
    wpx, hpx = 92, 236
    tw, th = int(stretch * hpx / wpx * 100), 100
    for k in range(2):
        cx = int(S * (0.25 + 0.5 * k))
        t = Image.new("RGBA", (tw, th), (0, 0, 0, 0))
        dt = ImageDraw.Draw(t)
        text_centered(dt, (0, 0, tw, 62), "SIGNAL  FLARE  " + gas.split("_")[1].upper(), font("impact.ttf", 58), ink)
        text_centered(dt, (0, 64, tw, 100), "STRIKE CAP  -  HOLD AWAY FROM FACE", font("consolab.ttf", 28), ink)
        t = t.rotate(90, expand=True).resize((wpx, hpx), Image.LANCZOS)
        body.paste(t, (cx - wpx // 2, 46), t)
    wear(body, 142, 80, tuple(min(255, c + 30) for c in col))
    paste_region(img, face_front(body), R_BODY)
    paste_region(img, noise_img((256, 192), (46, 40, 36), 10, 143, 1.2), R_METAL)    # зажигательная головка
    paste_region(img, noise_img((256, 192), tuple(int(c * 0.75) for c in col), 5, 144), R_CAP)
    return img


def tex_grenade(gas):
    paint, band, label, sub = GASES[gas]
    S = 512
    img = Image.new("RGB", (S, S))
    body = noise_img((S, 320), (96, 104, 62), 9, 11)
    d = ImageDraw.Draw(body)
    d.rectangle([0, 18, S, 70], fill=band if gas != "smoke" else (225, 225, 225))
    for k in range(2):                               # надпись дважды по окружности
        cx = S * (0.25 + 0.5 * k)
        text_centered(d, (cx - 120, 95, cx + 120, 150), label, font("impact.ttf", 46), (235, 225, 120) if gas != "smoke" else (240, 240, 240))
        text_centered(d, (cx - 120, 160, cx + 120, 185), sub, font("consolab.ttf", 16), (230, 230, 210))
        text_centered(d, (cx - 120, 250, cx + 120, 270), "AETHER M18-G  LOT 26-11", font("consolab.ttf", 13), (200, 200, 180))
    wear(body, 3, 90, (150, 150, 120))
    paste_region(img, face_front(body), R_BODY)
    paste_region(img, metal((256, 192), (120, 124, 120), 2), R_METAL)
    cap = metal((256, 192), (90, 94, 90), 4)
    paste_region(img, cap, R_CAP)
    return img


def tex_cylinder(gas):
    paint, band, label, sub = GASES[gas]
    S = 512
    img = Image.new("RGB", (S, S))
    body = noise_img((S, 384), paint, 8, 21)
    vert = Image.new("RGBA", (384, 140), (0, 0, 0, 0))   # вертикальная надпись: рисуем горизонтально и поворачиваем
    dv = ImageDraw.Draw(vert)
    text_centered(dv, (0, 0, 384, 90), label, font("impact.ttf", 80 if len(label) > 4 else 96), (250, 250, 245) if sum(paint) < 450 else (30, 30, 30))
    text_centered(dv, (0, 92, 384, 135), sub, font("consolab.ttf", 26), (240, 240, 230) if sum(paint) < 450 else (40, 40, 40))
    vert = vert.rotate(90, expand=True)
    for k in range(2):
        body.paste(vert, (int(S * (0.25 + 0.5 * k)) - vert.size[0] // 2, 0), vert)
    for k in range(2):   # панель маркировки справа от вертикальной надписи, с обеих сторон баллона
        hazard_panel(body, gas, int(S * (0.25 + 0.5 * k)) + 92, 6, 0.95)
    wear(body, 5, 140, tuple(min(255, c + 40) for c in paint))
    paste_region(img, face_front(body), (0, 0, 1, 0.75))
    shoulder = noise_img((256, 128), band if gas != "smoke" else (200, 200, 200), 6, 7)
    paste_region(img, shoulder, (0, 0.75, 0.5, 1))
    for im, rect in zip(valve_images(8), (CYL_BRASS, CYL_WHEEL)):   # латунь вентиля, красный маховик
        paste_region(img, im, rect)
    return img


# --- Три стиля баллонов: «su» — СССР (ГОСТ 949-73, изношенный), «nato» — армия США/НАТО (изношенный),
# «modern» — современный промышленный (EN 1089-3: цвет плеча по опасности, этикетка, лёгкие потёртости).
CYL_STYLES = ("su", "nato", "modern")

# СССР: газ → (краска, надпись, цвет надписи, полоса или None, подпись мелко)
GOST = {
    "smoke":    ((132, 136, 128), "ДЫМ", (20, 20, 20), (226, 226, 220), "ДЫМОВАЯ СМЕСЬ"),
    "chlorine": ((92, 96, 60), "ХЛОР", (226, 226, 214), (52, 120, 60), "ЯДОВИТ"),
    "methane":  ((150, 38, 32), "МЕТАН", (236, 236, 228), None, "ГОРЮЧИЙ ГАЗ"),
    "co_smoke": ((70, 66, 62), "УГАРНЫЙ ГАЗ", (210, 60, 40), (196, 120, 36), "CO  ЯДОВИТ"),
    "steam":    ((206, 206, 200), "ПАР", (170, 40, 34), (60, 110, 180), "ГОРЯЧО"),
    "tear_gas": ((132, 136, 128), "CS", (170, 36, 30), (190, 40, 34), "РАЗДРАЖАЮЩЕЕ ОВ"),
    "sarin":    ((80, 86, 58), "ЗАРИН", (196, 52, 40), (52, 120, 60), "ОВ  GB"),
    "mustard":  ((80, 86, 58), "ИПРИТ", (196, 52, 40), (210, 180, 40), "ОВ  HD"),
    "h2s":      ((210, 210, 204), "СЕРОВОДОРОД", (176, 34, 30), (176, 34, 30), "ЯДОВИТ  ГОРЮЧ"),
    "ammonia":  ((206, 172, 46), "АММИАК", (22, 22, 22), None, "ЕДКИЙ"),
    "hydrogen": ((44, 74, 50), "ВОДОРОД", (196, 44, 36), None, "ГОРЮЧИЙ ГАЗ"),
    "nitrogen": ((32, 32, 34), "АЗОТ", (214, 180, 40), (110, 70, 40), "ЖИДКИЙ"),
    "co2":      ((32, 32, 34), "УГЛЕКИСЛОТА", (214, 180, 40), None, "CO2"),
    "signal_red":    ((80, 86, 58), "СИГНАЛ", (230, 230, 220), (200, 50, 42), "КРАСНЫЙ ДЫМ"),
    "signal_green":  ((80, 86, 58), "СИГНАЛ", (230, 230, 220), (60, 160, 70), "ЗЕЛЁНЫЙ ДЫМ"),
    "signal_yellow": ((80, 86, 58), "СИГНАЛ", (230, 230, 220), (226, 196, 50), "ЖЁЛТЫЙ ДЫМ"),
    "signal_violet": ((80, 86, 58), "СИГНАЛ", (230, 230, 220), (130, 70, 180), "ФИОЛЕТОВЫЙ ДЫМ"),
    "signal_orange": ((80, 86, 58), "СИГНАЛ", (230, 230, 220), (230, 120, 36), "ОРАНЖЕВЫЙ ДЫМ"),
}

# НАТО/США: газ → (корпус, плечо, надпись, подпись, цвет трафарета, [полосы])
# Боеприпасы с ОВ — серые с зелёными полосами и зелёной маркировкой, ирританты — серые с красной,
# дымы — светло-зелёные с чёрной; промышленные газы армейского снабжения — олива, плечо по EN 1089-3.
OD, GREY, LGREEN = (78, 82, 58), (126, 128, 124), (112, 128, 92)
Y_SH, R_SH, K_SH, G_SH, W_SH = (204, 170, 40), (168, 40, 34), (34, 34, 36), (118, 120, 118), (222, 222, 216)
NATO = {
    "smoke":    (LGREEN, LGREEN, "SMOKE", "HC  SCREENING", (20, 20, 20), []),
    "chlorine": (OD, Y_SH, "CHLORINE", "UN 1017  TOXIC  CORROSIVE", (226, 226, 214), []),
    "methane":  (OD, R_SH, "METHANE", "UN 1971  FLAMMABLE GAS", (226, 226, 214), []),
    "co_smoke": (OD, Y_SH, "CARBON MONOXIDE", "UN 1016  TOXIC  FLAMMABLE", (226, 226, 214), []),
    "steam":    (GREY, W_SH, "STEAM", "HOT VAPOR  DO NOT HEAT", (20, 20, 20), []),
    "tear_gas": (GREY, GREY, "CS", "RIOT CONTROL AGENT", (176, 36, 30), [(176, 36, 30)]),
    "sarin":    (GREY, GREY, "GB", "NERVE AGENT  LETHAL", (40, 112, 58), [(40, 112, 58), (40, 112, 58)]),
    "mustard":  (GREY, GREY, "HD", "BLISTER AGENT  LETHAL", (40, 112, 58), [(40, 112, 58)]),
    "h2s":      (OD, Y_SH, "HYDROGEN SULFIDE", "UN 1053  TOXIC  FLAMMABLE", (226, 226, 214), []),
    "ammonia":  (OD, Y_SH, "AMMONIA ANHYDROUS", "UN 1005  TOXIC  CORROSIVE", (226, 226, 214), []),
    "hydrogen": (OD, R_SH, "HYDROGEN", "UN 1049  FLAMMABLE GAS", (226, 226, 214), []),
    "nitrogen": (OD, K_SH, "NITROGEN", "UN 1977  REFRIGERATED LIQUID", (226, 226, 214), []),
    "co2":      (OD, G_SH, "CARBON DIOXIDE", "UN 1013", (226, 226, 214), []),
    "signal_red":    (LGREEN, LGREEN, "SMOKE RED", "SIGNAL", (20, 20, 20), [(200, 50, 42)]),
    "signal_green":  (LGREEN, LGREEN, "SMOKE GREEN", "SIGNAL", (20, 20, 20), [(50, 140, 60)]),
    "signal_yellow": (LGREEN, LGREEN, "SMOKE YELLOW", "SIGNAL", (20, 20, 20), [(226, 196, 50)]),
    "signal_violet": (LGREEN, LGREEN, "SMOKE VIOLET", "SIGNAL", (20, 20, 20), [(120, 64, 170)]),
    "signal_orange": (LGREEN, LGREEN, "SMOKE ORANGE", "SIGNAL", (20, 20, 20), [(230, 120, 36)]),
}

# Современный: газ → (корпус, плечо EN 1089-3, название, формула)
MGREY, MRED, MWHITE = (148, 150, 150), (172, 42, 38), (214, 214, 210)
MODERN = {
    "smoke":    (MGREY, W_SH, "Smoke generator mix", "ZnCl2 aerosol"),
    "chlorine": (MGREY, Y_SH, "Chlorine", "Cl2"),
    "methane":  (MRED, MRED, "Methane", "CH4"),
    "co_smoke": (MGREY, Y_SH, "Carbon monoxide", "CO"),
    "steam":    (MWHITE, MWHITE, "Steam", "H2O"),
    "tear_gas": (MGREY, Y_SH, "CS irritant", "C10H5ClN2"),
    "sarin":    (MGREY, Y_SH, "Sarin (GB)", "C4H10FO2P"),
    "mustard":  (MGREY, Y_SH, "Sulfur mustard (HD)", "C4H8Cl2S"),
    "h2s":      (MGREY, Y_SH, "Hydrogen sulfide", "H2S"),
    "ammonia":  (MGREY, Y_SH, "Ammonia, anhydrous", "NH3"),
    "hydrogen": (MRED, MRED, "Hydrogen", "H2"),
    "nitrogen": ((92, 94, 96), K_SH, "Nitrogen, refrigerated", "N2"),
    "co2":      (MGREY, G_SH, "Carbon dioxide", "CO2"),
    "signal_red":    (MGREY, (200, 50, 42), "Signal smoke, red", ""),
    "signal_green":  (MGREY, (50, 140, 60), "Signal smoke, green", ""),
    "signal_yellow": (MGREY, (226, 196, 50), "Signal smoke, yellow", ""),
    "signal_violet": (MGREY, (120, 64, 170), "Signal smoke, violet", ""),
    "signal_orange": (MGREY, (230, 120, 36), "Signal smoke, orange", ""),
}
H_STATEMENTS = {   # краткие фразы опасности GHS для этикетки (настоящие формулировки H-фраз)
    "cyl": "H280 Contains gas under pressure; may explode if heated.",
    "skull": "H330 Fatal if inhaled.",
    "flame": "H220 Extremely flammable gas.",
    "corr": "H314 Causes severe skin burns and eye damage.",
    "oxid": "H270 May cause or intensify fire; oxidiser.",
    "excl": "H335 May cause respiratory irritation.",
}

CYL_W, CYL_H = 512, 384
# тексели корпуса: окружность 2π·4.5 ≈ 28.3 ед. на 512 пикс, высота 34 ед. на 384 → по v в 0.63 раза
# «реже»: надписи и наклейки сжимаются по вертикали, чтобы на модели сохранить пропорции
CYL_SQ = (2 * math.pi * 4.5 / CYL_W) / (34 / CYL_H)


def cyl_label(gas, name, formula, seed):
    """Этикетка современного баллона (как у промышленных газов): белая наклейка с названием, формулой,
    пиктограммами GHS, номером ООН, H-фразами мелким шрифтом и штрихкодом. Рисуется в 2× и уменьшается."""
    import texgen as T
    S = 2
    w, h = 168 * S, 128 * S
    img = Image.new("RGBA", (w, h), (238, 236, 228, 255))
    d = ImageDraw.Draw(img)
    hz = HAZARD.get(gas, HAZARD["smoke"])
    ghs, un = hz[4], hz[5]
    d.rectangle([0, 0, w, 6 * S], fill=(70, 74, 80, 255))
    d.text((6 * S, 10 * S), name, font=T.fit_font(name, w - 12 * S, 17 * S, "SemiBold"), fill=(24, 24, 26))
    if formula:
        d.text((6 * S, 31 * S), formula, font=T.font(11 * S, "Regular"), fill=(60, 60, 64))
    if un:
        d.text((w - 6 * S, 31 * S), "UN " + un, font=T.font(11 * S, "SemiBold"), fill=(24, 24, 26), anchor="ra")
    x = 6 * S + 13 * S
    for kind in ghs[:3]:
        ghs_pictogram(img, x, 60 * S, 12 * S, kind)
        x += 27 * S
    y = 76 * S
    small = T.font(6 * S, "Regular")
    for kind in ghs[:3]:
        d.text((6 * S, y), H_STATEMENTS.get(kind, ""), font=small, fill=(50, 50, 54))
        y += 8 * S
    d.text((6 * S, y), "P403 Store in a well-ventilated place.", font=small, fill=(50, 50, 54))
    rnd = random.Random(seed)      # штрихкод
    bx = w - 52 * S
    for i in range(40):
        if rnd.random() < 0.55:
            d.rectangle([bx + i * S, 48 * S, bx + i * S + (S - 1), 70 * S], fill=(20, 20, 20))
    d.text((bx, 72 * S), "%013d" % rnd.randrange(10 ** 12, 10 ** 13), font=T.font(5 * S, "Regular"), fill=(30, 30, 30))
    d.rectangle([0, 0, w - 1, h - 1], outline=(180, 178, 170, 255), width=S)
    img = img.resize((w // S, h // S), Image.LANCZOS)
    # пожелтение и загиб угла (наклейка отклеилась)
    a = np.asarray(img, float)
    a[..., :3] *= np.array([0.97, 0.95, 0.88])
    yy, xx = np.mgrid[0:a.shape[0], 0:a.shape[1]]
    corner = (xx + yy) < 14
    a[corner, 3] = 0
    return Image.fromarray(np.uint8(np.clip(a, 0, 255)), "RGBA")


CYL_BRASS, CYL_WHEEL = (0.5, 0.75, 0.75, 1), (0.75, 0.75, 1, 1)   # латунь вентиля / красный маховик


def _cyl_assemble(body, shoulder, brass, wheel):
    """Атлас баллона (раскладка tex_cylinder) из трёх слоёв texgen: цвет и нормали+блеск. Корпус сдвигается
    на четверть оборота (надписи на u = 0.25/0.75 встают на лицевую и тыльную стороны)."""
    import texgen as T
    q = -CYL_W // 4
    rgb = np.roll(body["rgb"], q, axis=1)
    color = Image.new("RGB", (512, 512))
    paste_region(color, Image.fromarray(np.uint8(np.clip(rgb, 0, 255))), (0, 0, 1, 0.75))
    paste_region(color, T.to_image(shoulder), (0, 0.75, 0.5, 1))
    paste_region(color, T.to_image(brass), CYL_BRASS)
    paste_region(color, T.to_image(wheel), CYL_WHEEL)
    nrm = Image.new("RGBA", (512, 512))
    paste_region(nrm, T.normal_image(np.roll(body["height"], q, axis=1), np.roll(body["gloss"], q, axis=1), 5), (0, 0, 1, 0.75))
    paste_region(nrm, T.normal_image(shoulder["height"], shoulder["gloss"], 5), (0, 0.75, 0.5, 1))
    paste_region(nrm, T.normal_image(brass["height"], brass["gloss"], 3), CYL_BRASS)
    paste_region(nrm, T.normal_image(wheel["height"], wheel["gloss"], 3), CYL_WHEEL)
    return color, nrm


def _cyl_brass(seed):
    """Латунь вентиля: потемневшая, с окислами."""
    import texgen as T
    brass = T.weathered_paint(256, 128, (150, 122, 62), seed + 200, wear=0.0, hits=0, rust=0.0, grime=0.5,
                              fade=0.3, gloss_paint=0.75)
    tarnish = np.clip(T.fbm(256, 128, seed + 201, ((20, 0.6), (6, 0.4))) * 0.8 + 0.3, 0, 1)[..., None]
    brass["rgb"] = brass["rgb"] * (1 - 0.45 * tarnish) + np.array([62, 58, 40.0]) * 0.45 * tarnish
    return brass


def _cyl_wheel(seed):
    """Маховик вентиля: латунь под красной эмалью (так красят маховики), краска облезла по ободу до латуни."""
    import texgen as T
    return T.weathered_paint(256, 128, (170, 36, 30), seed + 210, wear=1.1, rims=("top", "bottom"), rim_width=10,
                             hits=4, rust=0.0, grime=0.7, gloss_paint=0.4, primer=(150, 122, 62),
                             base_metal=(122, 100, 54))


def valve_images(seed=0):
    """Латунь и красный маховик — картинки для классических скинов (без карт нормалей)."""
    import texgen as T
    return T.to_image(_cyl_brass(seed)), T.to_image(_cyl_wheel(seed))


def tex_cylinder_styled(gas, style, seed=0):
    """Баллон в одном из стилей CYL_STYLES. Возвращает (цвет RGB, нормали RGBA с блеском в альфе).
    Узор износа зависит только от стиля и seed — одна карта нормалей на стиль годится для всех газов."""
    import texgen as T
    W, H, sq = CYL_W, CYL_H, CYL_SQ
    s = {"su": 31, "nato": 57, "modern": 83}[style] + seed
    if style == "su":
        paint, text, ink, stripe, sub = GOST[gas]
        body = T.weathered_paint(W, H, paint, s, wear=1.0, rims=("top", "bottom"), rim_width=22, hits=7, rust=0.9)
        if stripe:
            T.band(body, 92, 108, stripe, s)
        for k in range(2):   # ГОСТ: надпись горизонтально по окружности, ~1/3 окружности, у верха
            cx = W * (0.25 + 0.5 * k)
            T.stencil_text(body, text, T.fit_font(text, W // 3, 74), (cx, 52), ink, seed=s + k, squash=sq)
            T.stencil_text(body, sub, T.fit_font(sub, W // 3, 22, "SemiBold Condensed"), (cx, 128), ink,
                           seed=s + 5 + k, squash=sq, bridges=False, alpha=0.8)
            T.stencil_text(body, "№ %05d" % (1000 + (GAS_ORDER.index(gas) + 3) * 3797 % 90000),
                           T.font(18, "SemiBold Condensed"), (cx, H - 40),
                           (24, 24, 24) if sum(paint) > 300 else (210, 210, 200), seed=s + 9 + k, squash=sq,
                           bridges=False, alpha=0.7)
        sh = T.weathered_paint(256, 128, paint, s + 100, wear=1.3, rims=("top",), rim_width=30, hits=4, grime=0.3)
        for k in range(2):
            T.stamp(sh, "150 КГС  ГОСТ 949-73  %02d.%02d" % (3 + s % 9, 70 + s % 20),
                    T.font(12, "SemiBold Condensed"), (64 + 128 * k, 104), seed=s)
    elif style == "nato":
        paint, shoulder, text, sub, ink, bands = NATO[gas]
        body = T.weathered_paint(W, H, paint, s, wear=0.9, rims=("top", "bottom"), rim_width=20, hits=6,
                                 rust=0.7, grime=1.1, primer=T.PRIMER_ZINC)
        for i, c in enumerate(bands):   # полосы маркировки ОВ — у верха корпуса
            T.band(body, 16 + i * 22, 30 + i * 22, c, s + i)
        for k in range(2):   # трафарет по окружности + NSN и партия (армейская маркировка снабжения)
            cx = W * (0.25 + 0.5 * k)
            y0 = 30 + len(bands) * 22
            T.stencil_text(body, text, T.fit_font(text, W // 3, 64), (cx, y0 + 34), ink, seed=s + k, squash=sq)
            T.stencil_text(body, sub, T.fit_font(sub, W // 3, 20, "SemiBold Condensed"), (cx, y0 + 88), ink,
                           seed=s + 5 + k, squash=sq, bridges=False, alpha=0.85)
            nsn = "NSN 6830-01-%03d-%04d" % (100 + GAS_ORDER.index(gas) * 37, 1000 + GAS_ORDER.index(gas) * 571)
            T.stencil_text(body, nsn, T.font(16, "SemiBold Condensed"), (cx, H - 58), ink, seed=s + 9 + k,
                           squash=sq, bridges=False, alpha=0.75)
            T.stencil_text(body, "LOT %s-%02d" % ("ABCDEFGHJK"[GAS_ORDER.index(gas) % 10], 84 + k),
                           T.font(16, "SemiBold Condensed"), (cx, H - 38), ink, seed=s + 11 + k, squash=sq,
                           bridges=False, alpha=0.75)
        sh = T.weathered_paint(256, 128, shoulder, s + 100, wear=1.2, rims=("top",), rim_width=30, hits=4,
                               grime=0.3, primer=T.PRIMER_ZINC)
        for k in range(2):
            T.stamp(sh, "DOT-3AA2015  TW 54.2  %02d 8%d" % (3 + s % 9, s % 10), T.font(10, "SemiBold Condensed"),
                    (66 + 128 * k, 104), seed=s)
    else:   # modern
        paint, shoulder, name, formula = MODERN[gas]
        body = T.weathered_paint(W, H, paint, s, wear=0.18, rims=("top", "bottom"), rim_width=14, hits=3,
                                 rust=0.15, grime=0.35, fade=0.12, gloss_paint=0.55, primer=T.PRIMER_GREY)
        for k in range(2):   # этикетка на лицевой и тыльной сторонах
            T.decal(body, cyl_label(gas, name, formula, s + k), (W * (0.25 + 0.5 * k), 118), squash=sq,
                    wear=0.12, seed=s + k)
        sh = T.weathered_paint(256, 128, shoulder, s + 100, wear=0.35, rims=("top",), rim_width=20, hits=2,
                               rust=0.1, grime=0.15, fade=0.3, gloss_paint=0.55, primer=T.PRIMER_GREY)
        for k in range(2):   # «N» — отметка новой цветовой кодировки EN 1089-3 + клеймо испытаний
            T.stamp(sh, "N", T.font(22, "Bold"), (40 + 128 * k, 92), seed=s)
            T.stamp(sh, "EN ISO 9809-1  PH 300 BAR  %02d/2%d" % (1 + s % 12, 18 + s % 6),
                    T.font(10, "SemiBold Condensed"), (84 + 128 * k, 112), seed=s)
    return _cyl_assemble(body, sh, _cyl_brass(s), _cyl_wheel(s))


def tex_cylinder_go(gas, seed=0):
    """Советский стиль (совместимость с превью)."""
    return tex_cylinder_styled(gas, "su", seed)


def tex_cylinder_plain():
    """Старый баллон без надписей (машинима, сцены): выцветшая краска, неровные пятна ржавчины (низкочастотный
    шум с порогом, больше снизу), тонкие потёки, мелкие сколы до металла, потемневшая латунь.
    Та же раскладка, что у tex_cylinder."""
    S, H = 512, 384
    rnd = np.random.default_rng(121)
    base = np.array(noise_img((S, H), (82, 88, 78), 7, 121, 1.8)).astype(float)
    # пятна: шум двух масштабов, по u — периодический (по окружности баллона без шва)
    def field(scale, seed):
        r = np.random.default_rng(seed).normal(0, 1, (H // scale + 2, S // scale))
        img = Image.fromarray(np.uint8(np.clip(r * 40 + 128, 0, 255))).resize((S, H + 2 * scale), Image.BICUBIC)
        return (np.array(img).astype(float)[:H] - 128) / 40
    f = field(32, 1) * 0.7 + field(8, 2) * 0.3
    grad = np.linspace(-0.6, 0.9, H)[:, None]          # снизу ржавее
    mask = np.clip((f + grad - 0.55) * 1.6, 0, 1)
    rust = np.stack([np.full((H, S), 112.0), np.full((H, S), 60.0), np.full((H, S), 30.0)], -1)
    rust *= (0.75 + 0.5 * np.clip(field(4, 3) * 0.5 + 0.5, 0, 1))[..., None]
    out = base * (1 - mask[..., None] * 0.85) + rust * (mask[..., None] * 0.85)
    img_body = Image.fromarray(np.uint8(np.clip(out, 0, 255)))
    d = ImageDraw.Draw(img_body, "RGBA")
    rr = random.Random(122)
    for _ in range(26):   # потёки вниз от пятен
        x, y = rr.uniform(0, S), rr.uniform(0, H * 0.7)
        d.line([(x, y), (x + rr.uniform(-2, 2), y + rr.uniform(25, 80))], fill=(92, 50, 26, rr.randint(50, 110)),
               width=rr.randint(1, 3))
    for _ in range(60):   # сколы краски до металла
        x, y, r = rr.uniform(0, S), rr.uniform(0, H), rr.uniform(0.8, 2.6)
        d.ellipse([x - r, y - r * 0.7, x + r, y + r * 0.7], fill=(150, 148, 140, 220))
    img_body = img_body.filter(ImageFilter.GaussianBlur(0.6))
    img = Image.new("RGB", (S, S))
    paste_region(img, img_body, (0, 0, 1, 0.75))
    paste_region(img, noise_img((256, 128), (60, 64, 58), 6, 123, 1.6), (0, 0.75, 0.5, 1))
    for im, rect in zip(valve_images(124), (CYL_BRASS, CYL_WHEEL)):   # латунь вентиля, красный маховик
        paste_region(img, im, rect)
    return img


def tex_propane():
    """Бытовой пропановый баллон (СССР, ГОСТ 15860): красная эмаль со сколами до грунта и металла у башмака
    и кольца, ржавые потёки, белый трафарет «ПРОПАН» по окружности, клеймо на верхнем днище, латунный
    вентиль. Возвращает (цвет, нормали+блеск)."""
    import texgen as T
    s = 171
    W, H = 512, 320
    sq = (2 * math.pi * 5.6 / W) / (9.3 / H)
    body = T.weathered_paint(W, H, (168, 34, 30), s, wear=1.0, rims=("top", "bottom"), rim_width=26, hits=7,
                             rust=0.9, grime=1.1)
    for k in range(2):
        cx = W * (0.25 + 0.5 * k)
        T.stencil_text(body, "ПРОПАН", T.fit_font("ПРОПАН", W // 3, 80), (cx, 120), (236, 234, 226), seed=s + k,
                       squash=sq)
        T.stencil_text(body, "ОГНЕОПАСНО", T.fit_font("ОГНЕОПАСНО", W // 4, 26, "SemiBold Condensed"), (cx, 190),
                       (236, 234, 226), seed=s + 3 + k, squash=sq, bridges=False, alpha=0.85)
    for key in ("rgb", "height", "gloss"):
        body[key] = np.roll(body[key], -W // 4, axis=1)
    ends = T.weathered_paint(256, 192, (168, 34, 30), s + 10, wear=1.3, rims=("top", "bottom", "left", "right"),
                             rim_width=18, hits=5, rust=1.0, grime=1.0)
    T.stamp(ends, "ГОСТ 15860-84  50 Л  РАБ. 1,6 МПА  07.79", T.fit_font("ГОСТ 15860-84  50 Л  РАБ. 1,6 МПА  07.79", 240, 13,
                                                                          "SemiBold Condensed"), (128, 40), seed=s)
    brass = _cyl_brass(s + 20)
    brass = {"rgb": np.asarray(Image.fromarray(np.uint8(np.clip(brass["rgb"], 0, 255))).resize((256, 192)), float),
             "height": np.full((192, 256), 0.6), "gloss": np.full((192, 256), 0.7)}
    color, nrm = Image.new("RGB", (512, 512)), Image.new("RGBA", (512, 512))
    for layer, rect in ((body, R_BODY), (ends, R_METAL), (brass, R_CAP)):
        paste_region(color, T.to_image(layer), rect)
        paste_region(nrm, T.normal_image(layer["height"], layer["gloss"], 4), rect)
    return color, nrm


# Регионы корпусов с табличкой: краска, тёмный металл, мотор/корпус, табличка (натягивается целиком)
R_PAINT, R_DARK, R_HOUSING, R_PLATE = (0, 0, 1, 0.5), (0, 0.5, 0.5, 1), (0.5, 0.5, 1, 0.75), (0.5, 0.75, 1, 1)


def label_plate(text, aspect, bg, fg, stripe=None):
    """Табличка с надписью в пропорции грани aspect = ширина/высота (paste_region сожмёт её в регион,
    а на модели она снова растянется до верных пропорций)."""
    h = 96
    w = int(h * aspect)
    img = Image.new("RGB", (w, h), bg)
    d = ImageDraw.Draw(img)
    if stripe:
        stripes(img, (0, 0, h * 1.2, h), colors=stripe, width=14)
        stripes(img, (w - h * 1.2, 0, w, h), colors=stripe, width=14)
    x0 = int(h * 1.3) if stripe else 10
    size = int(h * 0.72)
    fnt = font("impact.ttf", size)
    while size > 10 and d.textlength(text, font=fnt) > w - 2 * x0:
        size -= 2
        fnt = font("impact.ttf", size)
    text_centered(d, (x0, 4, w - x0, h - 4), text, fnt, fg)
    d.rectangle([0, 0, w - 1, h - 1], outline=(20, 20, 20), width=3)
    return img


def tex_fan(paint=(118, 122, 126), label="EXHAUST FAN", plate_bg=(230, 230, 225), seed=41):
    S = 512
    img = Image.new("RGB", (S, S))
    frame = metal((S, 256), paint, seed)
    wear(frame, seed, 90)
    paste_region(img, frame, R_PAINT)
    paste_region(img, metal((256, 256), (60, 62, 66), 42), R_DARK)
    motor = metal((256, 128), (80, 96, 84), 43)
    d = ImageDraw.Draw(motor)
    for y in range(10, 120, 14):
        d.rectangle([20, y, 236, y + 5], fill=(40, 46, 42))
    paste_region(img, motor, R_HOUSING)
    fg = (25, 25, 25) if sum(plate_bg) > 300 else (245, 170, 60)
    paste_region(img, label_plate(label, 12.5, plate_bg, fg, ((235, 190, 30), (25, 25, 25))), R_PLATE)
    return img


M_RUBBER, M_GLASS, M_FILTER, M_METAL, M_STRAP = (0, 0, 1, 0.5), (0, 0.5, 0.5, 1), (0.5, 0.5, 1, 0.8), \
    (0.5, 0.8, 0.75, 1), (0.75, 0.8, 1, 1)


def rounded_outline(w, h, n=3.2, taper=0.0, seg=40):
    """Контур (u, v) суперэллипса |u/w|^n + |v/h|^n = 1. taper сужает нижнюю часть со стороны u < 0
    (к носу) — форма линз ГП-7 (скруглённая трапеция)."""
    pts = []
    for i in range(seg):
        t = 2 * math.pi * i / seg
        c, s = math.cos(t), math.sin(t)
        u = w * math.copysign(abs(c) ** (2 / n), c)
        v = h * math.copysign(abs(s) ** (2 / n), s)
        if v < 0 and u < 0:
            u *= 1 - taper * (-v / h)
        pts.append((u, v))
    return pts


def prism(mat, side_rect, cap_rect, outline, depth, base, w_axis, u_axis, bone=0, scale=1.0):
    """Призма по 2D-контуру: стенки от base вдоль w_axis на depth и передняя крышка (веер из центра).
    Контур выпуклый. u_axis — направление u контура, v = w × u."""
    m = Mesh()
    w = np.array(w_axis, float); w /= np.linalg.norm(w)
    u = np.array(u_axis, float); u -= w * np.dot(u, w); u /= np.linalg.norm(u)
    v = np.cross(w, u)
    b = np.array(base, float)
    P = [b + u * x * scale + v * y * scale for x, y in outline]
    N = len(P)
    per = sum(np.linalg.norm(P[(i + 1) % N] - P[i]) for i in range(N))
    acc = 0.0
    for i in range(N):
        a0, a1 = P[i], P[(i + 1) % N]
        seg_len = np.linalg.norm(a1 - a0)
        mid = (a0 + a1) / 2 - b
        nrm = mid - w * np.dot(mid, w)
        nrm /= np.linalg.norm(nrm) + 1e-9
        u0, u1 = acc / per, (acc + seg_len) / per
        acc += seg_len
        m.quad(mat, bone, (tuple(a0), tuple(nrm), uvmap(side_rect, u0, 1)), (tuple(a1), tuple(nrm), uvmap(side_rect, u1, 1)),
               (tuple(a1 + w * depth), tuple(nrm), uvmap(side_rect, u1, 0)), (tuple(a0 + w * depth), tuple(nrm), uvmap(side_rect, u0, 0)))
    xs = [p[0] for p in outline]; ys = [p[1] for p in outline]
    cu = lambda x, y: uvmap(cap_rect, (x - min(xs)) / (max(xs) - min(xs)), 1 - (y - min(ys)) / (max(ys) - min(ys)))
    c = b + w * depth
    for i in range(N):
        (x0, y0), (x1, y1) = outline[i], outline[(i + 1) % N]
        m.tri(mat, bone, (tuple(c), tuple(w), cu(0, 0) if min(xs) < 0 < max(xs) else cu(x0, y0)),
              (tuple(P[i] + w * depth), tuple(w), cu(x0, y0)), (tuple(P[(i + 1) % N] + w * depth), tuple(w), cu(x1, y1)))
    return m


# --- Противогаз (стиль ГП-7) ----------------------------------------------------------------------
LENS = dict(w=1.18, h=1.3, n=3.0, taper=0.38)


def tex_gasmask():
    """ГП-7: тёмно-серая матовая резина с пылью и потёртостями, тонированные линзы с царапинами,
    оливковая фильтрующая коробка ГП-7К с трафаретом и облезлой краской, воронёный металл обойм,
    тканевые ремни. Возвращает (цвет, нормали+блеск)."""
    import texgen as T
    s = 51
    rub = T.weathered_paint(512, 256, (50, 52, 52), s, wear=0.25, hits=2, rust=0.0, grime=0.7, fade=0.5,
                            gloss_paint=0.14, primer=(82, 84, 84))
    rub["height"] += T.fbm(512, 256, s + 3, ((2, 1),)) * 0.01            # зерно резины
    glass = T.weathered_paint(256, 256, (30, 42, 48), s + 1, wear=0, hits=0, rust=0, grime=0.25, fade=0.2,
                              gloss_paint=0.95)
    gl = Image.fromarray(np.uint8(np.clip(glass["rgb"], 0, 255)))
    d = ImageDraw.Draw(gl, "RGBA")
    d.ellipse([40, 30, 150, 116], fill=(120, 150, 160, 110))              # блик
    rr = random.Random(s)
    for _ in range(50):                                                    # царапины
        x, y, L_, a = rr.uniform(0, 256), rr.uniform(0, 256), rr.uniform(5, 40), rr.uniform(0, math.pi)
        d.line([(x, y), (x + L_ * math.cos(a), y + L_ * math.sin(a))], fill=(170, 185, 185, rr.randint(25, 70)))
    glass["rgb"] = np.asarray(gl.filter(ImageFilter.GaussianBlur(0.8)), float)

    fw, fh = 512, 154
    sq = (2 * math.pi * 2.0 / fw) / (2.7 / fh)
    flt = T.weathered_paint(fw, fh, (84, 92, 58), s + 2, wear=1.0, rims=("top", "bottom"), rim_width=16, hits=4,
                            rust=0.6, grime=0.8)
    for k in range(2):
        cx = fw * (0.25 + 0.5 * k)
        T.stencil_text(flt, "ГП-7К", T.fit_font("ГП-7К", fw // 4, 44), (cx, 52), (226, 222, 190), seed=s + k, squash=sq)
        T.stencil_text(flt, "ДАТА ИЗГ. 04-89  ПАРТ. 17", T.fit_font("ДАТА ИЗГ. 04-89  ПАРТ. 17", fw // 3, 16, "SemiBold Condensed"),
                       (cx, 92), (210, 206, 176), seed=s + 3 + k, squash=sq, bridges=False, alpha=0.75)
    flt["rgb"] = np.roll(flt["rgb"], -fw // 4, axis=1)
    for key in ("height", "gloss"):
        flt[key] = np.roll(flt[key], -fw // 4, axis=1)
    met = T.weathered_paint(128, 102, (34, 34, 36), s + 4, wear=1.1, hits=3, rust=0.3, grime=0.4,
                            primer=(70, 70, 72), gloss_paint=0.35)
    strap = T.weathered_paint(128, 102, (62, 64, 54), s + 5, wear=0, hits=0, rust=0, grime=1.0, fade=0.6,
                              gloss_paint=0.05)
    for x in range(0, 128, 4):                                            # плетение ленты
        strap["rgb"][:, x] *= 0.82
        strap["height"][:, x] -= 0.04
    color, nrm = Image.new("RGB", (512, 512)), Image.new("RGBA", (512, 512))
    for layer, rect in ((rub, M_RUBBER), (glass, M_GLASS), (flt, M_FILTER), (met, M_METAL), (strap, M_STRAP)):
        paste_region(color, T.to_image(layer), rect)
        paste_region(nrm, T.normal_image(layer["height"], layer["gloss"], 4), rect)
    return color, nrm


def mask_lens(mat, p, ax, sy, parts):
    """Линза ГП-7 на оболочке: обойма (металл), стекло, кант-кольцо. sy — сторона (+1 левая, −1 правая)."""
    w = np.array(ax, float); w /= np.linalg.norm(w)
    up = np.array([0.0, 0, 1]) - w * w[2]
    up /= np.linalg.norm(up)
    u = np.cross(up, w)
    if u[1] * sy < 0:
        u = -u                                          # u — наружу (от носа)
    o = rounded_outline(**LENS)
    parts.append(prism(mat, M_METAL, M_METAL, o, 0.36, p - w * 0.12, w, u, scale=1.16))
    parts.append(prism(mat, M_METAL, M_GLASS, o, 0.42, p - w * 0.06, w, u))
    ring = [tuple(p + w * 0.36 + (u * x + np.cross(w, u) * y) * 1.1) for x, y in o]
    parts.append(tube(mat, M_METAL, ring + [ring[0]], 0.15, 6))


def model_gasmask():
    """Противогаз в духе ГП-7. Оси: X вперёд, Y влево, Z вверх; центр линз — на высоте 0.
    Лицевая часть — оболочка с охватом щёк до ушей, подбородочная чашка выдвинута вперёд, кант по краю.
    Линзы — скруглённые трапеции в обоймах (ГП-7), спереди переговорное устройство с клапанной коробкой,
    фильтр ГП-7К с рёбрами на левой щеке, заглушка второго порта на правой, «паук» из 5 ремней."""
    mat = "gasmask"
    C = np.array([-2.6, 0.0, -0.6])                 # центр оболочки
    RX, RY, RZ = 4.2, 3.45, 4.6
    TH0, TH1, PH = -1.22, 1.05, 1.78               # подбородок, лоб, охват по бокам (рад)

    def face(th, ph):
        low = max(0.0, -math.sin(th))
        ry = RY * (1 - 0.22 * low ** 2)            # сужение к подбородку
        x = RX * math.cos(th) * math.cos(ph) + 1.25 * low ** 1.5 * max(0.0, math.cos(ph))   # чашка вперёд
        y = ry * math.cos(th) * math.sin(ph)
        z = RZ * math.sin(th)
        return tuple(C + np.array([x, y, z]))

    def surf(th, ph, off=0.0):
        e = 1e-3
        p = np.array(face(th, ph))
        du = np.array(face(th, ph + e)) - np.array(face(th, ph - e))
        dv = np.array(face(th + e, ph)) - np.array(face(th - e, ph))
        n = np.cross(du, dv)
        if np.dot(n, p - C) < 0:
            n = -n
        n /= np.linalg.norm(n)
        return p + n * off, n

    shell = param_surface(mat, M_RUBBER, face, TH0, TH1, -PH, PH, 22, 30, center=tuple(C))
    parts = [double_sided(shell)]
    edge = [face(TH0, -PH + 2 * PH * i / 30) for i in range(31)] + [face(TH0 + (TH1 - TH0) * i / 16, PH) for i in range(1, 17)] \
        + [face(TH1, PH - 2 * PH * i / 30) for i in range(1, 31)] + [face(TH1 - (TH1 - TH0) * i / 16, -PH) for i in range(1, 17)]
    parts.append(tube(mat, M_RUBBER, edge, 0.2, 6))

    for sy in (-1, 1):
        ph = 0.42 * sy
        th = math.asin((0.0 - C[2]) / RZ)
        p, n = surf(th, ph)
        ax = n * 0.55 + np.array([1.0, 0, 0]) * 0.45
        mask_lens(mat, p, ax / np.linalg.norm(ax), sy, parts)

    # переговорное устройство: широкая обойма, мембрана под решёткой (кольца), клапанная коробка ниже
    p, n = surf(-0.6, 0.0)
    ax = n * 0.6 + np.array([1.0, 0, -0.3]) * 0.4
    ax /= np.linalg.norm(ax)
    parts.append(cylinder(mat, M_METAL, 1.25, 0.8, 28, base=tuple(p - ax * 0.25), axis=tuple(ax), cap_rect=M_RUBBER))
    parts.append(torus(mat, M_METAL, 1.25, 0.16, center=tuple(p + ax * 0.55), axis=tuple(ax), seg=28, side=6))
    for r in (0.85, 0.5):   # решётка мембраны — концентрические рёбра
        parts.append(torus(mat, M_METAL, r, 0.07, center=tuple(p + ax * 0.58), axis=tuple(ax), seg=24, side=4))
    q, nq = surf(-0.98, 0.0)
    parts.append(cylinder(mat, M_METAL, 0.72, 0.75, 20, base=tuple(q - nq * 0.2), axis=tuple(nq), cap_rect=M_STRAP))
    parts.append(torus(mat, M_METAL, 0.72, 0.1, center=tuple(q + nq * 0.55), axis=tuple(nq), seg=20, side=5))

    # фильтр ГП-7К на левой щеке (+Y): горловина, коробка с двумя рёбрами жёсткости, донце
    p, n = surf(-0.55, 0.92)
    fa = n * 0.5 + np.array([0.75, 0.25, -0.45]) * 0.5
    fa /= np.linalg.norm(fa)
    parts.append(cylinder(mat, M_METAL, 0.85, 0.75, 18, base=tuple(p - fa * 0.2), axis=tuple(fa), cap_rect=M_METAL))
    base = p + fa * 0.5
    parts += filter_parts(mat, base, fa)
    # второй порт на правой щеке — заглушка
    p, n = surf(-0.55, -0.92)
    pa = n * 0.5 + np.array([0.75, -0.25, -0.45]) * 0.5
    pa /= np.linalg.norm(pa)
    parts.append(cylinder(mat, M_METAL, 0.8, 0.55, 18, base=tuple(p - pa * 0.2), axis=tuple(pa), cap_rect=M_METAL))
    parts.append(cylinder(mat, M_METAL, 0.95, 0.3, 18, base=tuple(p + pa * 0.35), axis=tuple(pa), cap_rect=M_METAL))

    # оголовье «паук»
    H = np.array([-3.0, 0.0, 0.3])
    HR = np.array([4.4, 3.65, 4.7])

    def on_head(d, off=0.18):
        d = d / np.linalg.norm(d)
        k = 1 / math.sqrt((d[0] / HR[0]) ** 2 + (d[1] / HR[1]) ** 2 + (d[2] / HR[2]) ** 2)
        p = H + d * k
        n = (p - H) / HR ** 2
        n /= np.linalg.norm(n)
        return p + n * off, n

    back = np.array([-1.0, 0.0, 0.35])
    anchors = [(TH1 - 0.05, 0.0)] + [(th, s * (PH - 0.05)) for s in (-1, 1) for th in (0.72, -0.35)]
    for th, ph in anchors:
        a = np.array(face(th, ph))
        d0, d1 = (a - H), back
        pts, nrm = [], []
        for i in range(17):
            t = i / 16
            d = d0 / np.linalg.norm(d0) * (1 - t) + d1 / np.linalg.norm(d1) * t
            p, n = on_head(d)
            if i == 0:
                p = a
            pts.append(p)
            nrm.append(n)
        parts.append(ribbon(mat, M_STRAP, pts, nrm, 0.75))
        parts.append(box(mat, M_METAL, tuple(a - 0.3), tuple(a + 0.3)))
    p, n = on_head(back, 0.22)
    parts.append(cylinder(mat, M_STRAP, 1.3, 0.12, 20, base=tuple(p), axis=tuple(n), cap_rect=M_STRAP))
    m = combine(*parts)
    phys = box("phys", M_RUBBER, (-7.2, -3.8, -5.6), (2.8, 3.8, 4.4))
    return m, phys, [("root", -1, (0, 0, 0))], 1, "rubber", None


def filter_parts(mat, base, axis):
    """Фильтрующая коробка ГП-7К: корпус ∅4 × 2.7, два выштампованных ребра, кольца завальцовки, донце."""
    a = np.array(axis, float); a /= np.linalg.norm(a)
    b = np.array(base, float)
    return [
        cylinder(mat, M_FILTER, 2.0, 2.7, 30, base=tuple(b), axis=tuple(a), cap_rect=M_METAL, fit=False),
        torus(mat, M_FILTER, 2.02, 0.07, center=tuple(b + a * 0.9), axis=tuple(a), seg=30, side=4),
        torus(mat, M_FILTER, 2.02, 0.07, center=tuple(b + a * 1.8), axis=tuple(a), seg=30, side=4),
        torus(mat, M_METAL, 2.0, 0.12, center=tuple(b + a * 2.7), axis=tuple(a), seg=30, side=5),
        torus(mat, M_METAL, 2.0, 0.12, center=tuple(b), axis=tuple(a), seg=30, side=5),
    ]


def model_filter():
    """Фильтрующая коробка ГП-7К отдельно (запасной фильтр): материал противогаза, ось Z, горловина сверху."""
    mat = "gasmask"
    m = combine(*filter_parts(mat, (0, 0, 0), (0, 0, 1)),
                cylinder(mat, M_METAL, 0.85, 0.75, 18, base=(0, 0, 2.7), cap_rect=M_METAL),
                torus(mat, M_METAL, 0.9, 0.1, center=(0, 0, 3.3), seg=18, side=5))
    phys = cylinder("phys", M_FILTER, 2.0, 3.45, 10)
    return m, phys, [("root", -1, (0, 0, 0))], 1, "plastic", None


# --- Противогаз ГП-7 из сторонней модели ------------------------------------------------------------
# «GP7 Gasmask» — Shadoff (https://sketchfab.com/dimas.karmanov), CC BY 4.0,
# https://sketchfab.com/3d-models/gp7-gasmask-844e2d7c0229413281abcf2cf1b99e66
# Изменения: поворот осей и масштаб под Source, AO запечено в цвет, нормали переведены в DirectX,
# блеск — из шероховатости/металличности, своё стекло линз. Без файла — процедурная модель выше.
GP7_GLB = os.path.join(_REPO, "assets", "third_party", "gp7_gasmask", "gp7_gasmask.glb")
GP7_SCALE = 31.0                        # метры → юниты под голову персонажа HL2 (ширина маски ≈ 7.5)
_gp7 = None


GP7_TARGET = {"m_gp7": 9000, "m_filter": 1600}   # треугольников после упрощения (было 44 929 и 4 412)


def decimate(pos, nrm, uv, idx, target):
    """Упрощение сетки (pyfqmr, quadric edge collapse) с сохранением UV.
    Швы UV в GLB — разрезы сетки (вершины продублированы), поэтому preserve_border держит их на месте и острова
    UV не «расползаются». UV и нормаль новой вершины — от ближайшей исходной вершины того же меша (упрощение
    двигает вершины мало). Нормали затем сглаживаются по совпадающим позициям, чтобы на швах не было ступенек."""
    import pyfqmr
    s = pyfqmr.Simplify()
    s.setMesh(np.asarray(pos, np.float64), np.asarray(idx, np.int32))
    s.simplify_mesh(target_count=target, aggressiveness=5, preserve_border=True, verbose=False)
    v, f, _ = s.getMesh()
    # ближайшая исходная вершина (порциями, без огромной матрицы расстояний)
    src = np.asarray(pos, float)
    near = np.empty(len(v), np.int64)
    for a in range(0, len(v), 512):
        d = ((v[a:a + 512, None, :] - src[None, :, :]) ** 2).sum(-1)
        near[a:a + 512] = d.argmin(1)
    new_uv = np.asarray(uv)[near]
    # нормали: по граням, затем среднее по одинаковым позициям (через швы UV)
    fn = np.cross(v[f[:, 1]] - v[f[:, 0]], v[f[:, 2]] - v[f[:, 0]])
    vn = np.zeros_like(v)
    for k in range(3):
        np.add.at(vn, f[:, k], fn)
    key = np.round(v, 4)
    _, inv = np.unique(key, axis=0, return_inverse=True)
    inv = inv.reshape(-1)
    acc = np.zeros((inv.max() + 1, 3))
    np.add.at(acc, inv, vn)
    vn = acc[inv]
    vn /= np.linalg.norm(vn, axis=1, keepdims=True) + 1e-12
    # ориентация граней — как у исходных нормалей (у double-sided меша pyfqmr может перевернуть)
    on = np.asarray(nrm)[near]
    flip = (vn * on).sum(1) < 0
    vn[flip] *= -1
    return v, vn, new_uv, f


def gp7():
    """Загрузить GLB один раз и перевести в оси Source: X вперёд (glTF +Z), Y влево (glTF +X — левая щека,
    там фильтр), Z вверх (glTF +Y). Центр линз — на высоте 0 и 1.2 впереди начала (глаза, cl_effects)."""
    global _gp7
    if _gp7 is None:
        from import_glb import load_glb
        g = load_glb(GP7_GLB)
        lens = next(m for m in g["meshes"] if m["material"] == "m_gp7_lens")
        lc = lens["pos"].mean(0)
        off = np.array([1.2 - lc[2] * GP7_SCALE, -lc[0] * GP7_SCALE, -lc[1] * GP7_SCALE])
        for m in g["meshes"]:
            p, n = m["pos"], m["nrm"]
            m["src_pos"] = np.c_[p[:, 2], p[:, 0], p[:, 1]] * GP7_SCALE + off
            m["src_nrm"] = np.c_[n[:, 2], n[:, 0], n[:, 1]]
            target = GP7_TARGET.get(m["material"])
            if target and len(m["idx"]) > target:
                try:   # pyfqmr (pip install pyfqmr); нет его — модель как есть
                    m["src_pos"], m["src_nrm"], m["uv"], m["idx"] = decimate(m["src_pos"], m["src_nrm"], m["uv"],
                                                                            m["idx"], target)
                except ImportError:
                    print("pyfqmr not installed: gas mask is not simplified")
        _gp7 = g
    return _gp7


def gp7_available():
    return os.path.exists(GP7_GLB)


GP7_MAT = {"m_gp7": "gasmask", "m_filter": "gasmask_filter", "m_gp7_lens": "gasmask_lens"}


def gp7_mesh(materials=None, M=np.eye(3), t=(0, 0, 0)):
    """Меш Mesh из GLB (все материалы или только перечисленные), с поворотом M и сдвигом t."""
    out = Mesh()
    t = np.array(t, float)
    for m in gp7()["meshes"]:
        if materials and m["material"] not in materials:
            continue
        name = GP7_MAT.get(m["material"], "gasmask")
        P = m["src_pos"] @ M.T + t
        N = m["src_nrm"] @ M.T
        U = m["uv"]
        for a, b, c in m["idx"]:
            out.tris.append((name, 0, [(tuple(P[i]), tuple(N[i]), (float(U[i, 0]), float(U[i, 1]))) for i in (a, b, c)]))
    return out


def gp7_textures():
    """Материалы ГП-7: цвет × AO (R карты metallicRoughness), нормали OpenGL → DirectX (инверсия G),
    блеск в альфе нормалей = гладкость (1 − roughness) с прибавкой за металл. Стекло — тонированное,
    полупрозрачное, с отражением окружения."""
    g = gp7()
    out = {}
    for src, name in (("m_gp7", "gasmask"), ("m_filter", "gasmask_filter")):
        mt = g["materials"][src]
        base = np.asarray(mt["baseColor"].convert("RGB"), float)
        mr = np.asarray(mt["mr"].convert("RGB"), float) / 255
        ao = mr[..., 0]
        base *= (0.35 + 0.65 * ao)[..., None]
        color = Image.fromarray(np.uint8(np.clip(base, 0, 255))).resize((512, 512), Image.LANCZOS)   # 1024 → 512: вчетверо легче
        nrm = np.asarray(mt["normal"].convert("RGB"), float)
        nrm[..., 1] = 255 - nrm[..., 1]
        gloss = np.clip((1 - mr[..., 1]) * 0.85 + mr[..., 2] * 0.25, 0, 1) * 255
        nimg = Image.fromarray(np.uint8(np.dstack([nrm, gloss])), "RGBA").resize((512, 512), Image.LANCZOS)
        save_normal(name + "_n", nimg)
        out[name] = (color, [f'"$bumpmap" "models/aether/{name}_n"', '"$phong" "1"', '"$phongexponent" "14"',
                             '"$phongboost" "1.2"', '"$phongfresnelranges" "[0.3 0.6 1]"',
                             '"$envmap" "env_cubemap"', '"$normalmapalphaenvmapmask" "1"',
                             '"$envmaptint" "[0.12 0.12 0.12]"', '"$nocull" "1"'])
    rnd = np.random.default_rng(7)
    lens = np.zeros((128, 128, 4))
    lens[..., :3] = np.array([34, 46, 50.0]) + rnd.normal(0, 2, (128, 128, 1))
    lens[..., 3] = 150
    out["gasmask_lens"] = (Image.fromarray(np.uint8(np.clip(lens, 0, 255)), "RGBA"),
                           ['"$translucent" "1"', '"$envmap" "env_cubemap"', '"$envmaptint" "[0.45 0.45 0.45]"',
                            '"$nocull" "1"'])
    return out


def model_gasmask_gp7():
    m = gp7_mesh()
    phys = box("phys", M_RUBBER, (-6.0, -3.9, -5.4), (3.2, 4.6, 3.6))
    return m, phys, [("root", -1, (0, 0, 0))], 1, "rubber", None


def model_filter_gp7():
    """Запасной фильтр: тот же фильтр из модели ГП-7 стоймя (ось по Z, горловина вверх, донце на z = 0).
    Ось: грубо — от центра коробки к горловине (8 % вершин, ближайших к центру лицевой части), точно —
    та из главных осей вершин, что ближе всего к этому направлению (горловина сбивает чистый PCA)."""
    g = gp7()
    f = next(m for m in g["meshes"] if m["material"] == "m_filter")
    P = f["src_pos"]
    c = P.mean(0)
    face_c = next(m for m in g["meshes"] if m["material"] == "m_gp7")["src_pos"].mean(0)
    d = np.linalg.norm(P - face_c, axis=1)
    neck = P[d <= np.quantile(d, 0.08)].mean(0)
    rough = (neck - c) / np.linalg.norm(neck - c)
    _, _, vt = np.linalg.svd(P - c, full_matrices=False)
    ax = max(vt, key=lambda v: abs(np.dot(v, rough)))
    if np.dot(ax, rough) < 0:       # горловина — вверх
        ax = -ax
    R = rot_z_to(ax).T              # ax → +Z
    q = (P - c) @ R.T
    m = gp7_mesh(["m_filter"], R, -R @ c + np.array([0, 0, -q[:, 2].min()]))
    h = q[:, 2].max() - q[:, 2].min()
    r = np.linalg.norm(q[:, :2], axis=1).max()
    phys = cylinder("phys", M_FILTER, r, h, 10)
    return m, phys, [("root", -1, (0, 0, 0))], 1, "plastic", None


# --- Газоанализатор (армейский переносной прибор) --------------------------------------------------
A_CASE, A_SCREEN, A_DARK, A_STEEL, A_DIAL, A_PANEL = (0, 0, 1, 0.5), (0, 0.5, 0.25, 0.75), (0.25, 0.5, 0.5, 0.75), \
    (0.5, 0.5, 0.75, 0.75), (0.75, 0.5, 1, 0.75), (0, 0.75, 0.5, 1)
A_BACK = (0.5, 0.75, 1, 1)


def tex_analyzer():
    """Корпус — окрашенная оливой сталь с износом и трафаретом «ГА-1»; экран — тёмный ЖК под стеклом;
    резина и бакелит — чёрные; сталь — тумблеры и зонд; шкала стрелочного индикатора; панель управления
    — светлая гравированная табличка с подписями (ПИТ., РЕЖИМ, ПОРОГ, ЗВУК)."""
    import texgen as T
    s = 61
    case = T.weathered_paint(512, 256, (84, 90, 64), s, wear=1.0, rims=("top", "bottom", "left", "right"),
                             rim_width=14, hits=5, rust=0.6, grime=0.9)
    screen = T.weathered_paint(128, 128, (14, 26, 18), s + 1, wear=0, hits=0, rust=0, grime=0.2, gloss_paint=0.9)
    dark = T.weathered_paint(128, 128, (30, 30, 32), s + 2, wear=0.3, hits=1, rust=0, grime=0.8, gloss_paint=0.15,
                             primer=(56, 56, 58))
    steel = T.weathered_paint(128, 128, (150, 152, 150), s + 3, wear=0, hits=0, rust=0.25, grime=0.5, gloss_paint=0.6)
    dial = Image.new("RGB", (128, 128), (226, 222, 204))   # шкала стрелочного индикатора 0..100 %
    dd = ImageDraw.Draw(dial)
    for k in range(11):
        a = math.radians(210 - k * 24)
        r0 = 44 if k % 5 else 38
        dd.line([(64 + r0 * math.cos(a), 70 - r0 * math.sin(a)), (64 + 54 * math.cos(a), 70 - 54 * math.sin(a))],
                fill=(20, 20, 20), width=2)
    dd.arc([10, 16, 118, 124], -30, 30, fill=(190, 40, 30), width=6)
    dd.line([(64, 70), (64 + 46 * math.cos(math.radians(150)), 70 - 46 * math.sin(math.radians(150)))], fill=(20, 20, 20), width=3)
    dd.ellipse([58, 64, 70, 76], fill=(20, 20, 20))
    dd.text((64, 100), "%", font=T.font(16, "SemiBold"), fill=(20, 20, 20), anchor="mm")
    dial_l = {"rgb": np.asarray(dial, float) * 0.95, "height": np.full((128, 128), 0.6), "gloss": np.full((128, 128), 0.6)}
    panel_img = Image.new("RGB", (256, 128), (176, 176, 168))   # гравированная табличка панели управления
    dp = ImageDraw.Draw(panel_img)
    f = T.font(15, "SemiBold Condensed")
    # подписи под органами (координаты как в model_analyzer: тумблеры y −1.1 и −0.4, ручка 0.9 над шкалой)
    for text, u in (("ПИТ.", 0.18), ("РЕЖИМ", 0.39), ("ПОРОГ", 0.76)):
        dp.text((u * 256, 112), text, font=f, fill=(24, 24, 24), anchor="mm")
    dp.text((0.28 * 256, 14), "ВКЛ", font=f, fill=(24, 24, 24), anchor="mm")
    dp.rectangle([1, 1, 254, 126], outline=(60, 60, 58), width=2)
    for x, y in ((8, 8), (248, 8), (8, 120), (248, 120)):        # винты
        dp.ellipse([x - 4, y - 4, x + 4, y + 4], fill=(110, 110, 106), outline=(50, 50, 50))
    panel = T.weathered_paint(256, 128, (176, 176, 168), s + 4, wear=0.4, hits=1, rust=0.1, grime=0.6)
    panel["rgb"] = panel["rgb"] * 0.25 + np.asarray(panel_img, float) * 0.75
    color, nrm = Image.new("RGB", (512, 512)), Image.new("RGBA", (512, 512))
    for layer, rect in ((case, A_CASE), (screen, A_SCREEN), (dark, A_DARK), (steel, A_STEEL), (dial_l, A_DIAL),
                        (panel, A_PANEL)):
        paste_region(color, T.to_image(layer), rect)
        paste_region(nrm, T.normal_image(layer["height"], layer["gloss"], 4), rect)
    # табличка-трафарет на тыльной стенке (3.2 × 2.4 ед.): рисуется 171 × 128, растягивается на регион 256 × 128
    back = T.weathered_paint(171, 128, (84, 90, 64), s + 6, wear=0.7, hits=2, rust=0.5, grime=0.8)
    T.stencil_text(back, "ГА-1", T.font(48), (85, 36), (226, 222, 196), seed=s + 7)
    T.stencil_text(back, "ГАЗОАНАЛИЗАТОР", T.fit_font("ГАЗОАНАЛИЗАТОР", 150, 24, "SemiBold Condensed"), (85, 78),
                   (226, 222, 196), seed=s + 8, bridges=False, alpha=0.85)
    T.stencil_text(back, "№ 004718", T.font(15, "SemiBold Condensed"), (85, 108), (226, 222, 196), seed=s + 9,
                   bridges=False, alpha=0.7)
    paste_region(color, T.to_image(back), A_BACK)
    paste_region(nrm, T.normal_image(back["height"], back["gloss"], 4), A_BACK)
    return color, nrm


def model_analyzer():
    """Переносной газоанализатор (оси: +X — лицевая сторона с экраном, Z вверх). Корпус 2 × 4 × 6.2 с
    резиновыми угловыми накладками и чехлом снизу; экран в выступающей рамке (лицевая плоскость экрана
    x = 1.12, угол (1.13, −1.6, 6.4), 3.2 × 2.7 — SCREEN_TL в weapon_aether_analyzer.lua); под ним панель
    с двумя тумблерами, ручкой порога и стрелочным индикатором; сверху — пробоотборный зонд со шлангом,
    по бокам — проушины ремня."""
    mat = "analyzer"
    parts = [
        box(mat, A_CASE, (-1.0, -2.0, 0.8), (1.0, 2.0, 7.0)),
        box(mat, A_DARK, (-1.1, -2.1, 0.0), (1.1, 2.1, 0.9)),                 # резиновый чехол снизу
        box(mat, A_DARK, (-1.08, -2.08, 6.85), (1.08, 2.08, 7.15)),           # резиновый кант сверху
        box(mat, A_SCREEN, (1.0, -1.6, 3.7), (1.12, 1.6, 6.4), fit=False),     # экран
        # рамка экрана — выступает на 0.12 перед стеклом
        box(mat, A_DARK, (1.0, -1.82, 6.4), (1.26, 1.82, 6.66)),
        box(mat, A_DARK, (1.0, -1.82, 3.44), (1.26, 1.82, 3.7)),
        box(mat, A_DARK, (1.0, -1.82, 3.7), (1.26, -1.6, 6.4)),
        box(mat, A_DARK, (1.0, 1.6, 3.7), (1.26, 1.82, 6.4)),
        box(mat, A_PANEL, (1.0, -1.75, 1.0), (1.06, 1.75, 3.3), fit=False),  # панель управления
        box(mat, A_BACK, (-1.03, -1.6, 4.2), (-1.0, 1.6, 6.6), fit=False),   # табличка на тыльной стенке
    ]
    for sx in (-1, 1):   # угловые накладки по вертикальным рёбрам
        for sy in (-1, 1):
            x0, y0 = (0.82, 1.82)
            parts.append(box(mat, A_DARK, (min(sx * 1.08, sx * x0), min(sy * 2.08, sy * y0), 0.9),
                             (max(sx * 1.08, sx * x0), max(sy * 2.08, sy * y0), 6.9)))
    for y in (-1.1, -0.4):   # тумблеры: основание, гайка, рычажок вверх
        parts.append(cylinder(mat, A_STEEL, 0.2, 0.12, 14, base=(1.06, y, 2.3), axis=(1, 0, 0), cap_rect=A_STEEL))
        parts.append(cylinder(mat, A_STEEL, 0.13, 0.12, 6, base=(1.18, y, 2.3), axis=(1, 0, 0), cap_rect=A_STEEL))
        parts.append(cylinder(mat, A_STEEL, 0.05, 0.55, 8, base=(1.25, y, 2.3), axis=(0.7, 0, 0.7), r_top=0.07, cap_rect=A_STEEL))
    parts.append(cylinder(mat, A_DIAL, 0.62, 0.06, 28, base=(1.06, 0.95, 1.75), axis=(1, 0, 0), cap_rect=A_DIAL, fit=False))
    parts.append(torus(mat, A_STEEL, 0.64, 0.07, center=(1.13, 0.95, 1.75), axis=(1, 0, 0), seg=28, side=5))
    parts.append(cylinder(mat, A_DARK, 0.3, 0.32, 16, base=(1.06, 0.95, 2.85), axis=(1, 0, 0), cap_rect=A_DARK))   # ручка порога
    parts.append(box(mat, A_STEEL, (1.37, 0.92, 2.85), (1.4, 0.98, 3.12)))                                        # метка ручки
    # зонд: штуцер на крышке, металлическая трубка, наконечник; шланг к боковому штуцеру
    parts.append(cylinder(mat, A_STEEL, 0.3, 0.3, 14, base=(0, 1.3, 7.15), cap_rect=A_STEEL))
    parts.append(cylinder(mat, A_STEEL, 0.13, 3.3, 10, base=(0, 1.3, 7.45), cap_rect=A_STEEL))
    parts.append(cylinder(mat, A_DARK, 0.24, 0.55, 12, base=(0, 1.3, 10.75), cap_rect=A_DARK))
    parts.append(cylinder(mat, A_STEEL, 0.22, 0.4, 12, base=(0, 2.08, 5.6), axis=(0, 1, 0), cap_rect=A_STEEL))
    parts.append(tube(mat, A_DARK, [(0, 2.45, 5.6), (0, 2.9, 6.1), (0, 2.7, 7.4), (0, 1.75, 8.1), (0, 1.43, 8.4)], 0.15, 8))
    for sy in (-1, 1):   # проушины ремня
        parts.append(torus(mat, A_STEEL, 0.32, 0.07, center=(0, sy * 2.15, 6.3), axis=(1, 0, 0), seg=14, side=4))
    m = combine(*parts)
    phys = box("phys", A_CASE, (-1.1, -2.1, 0), (1.26, 2.1, 7.15))
    return m, phys, [("root", -1, (0, 0, 0))], 1.2, "metal", None


# --- Распылитель: аэрозольный баллон на пистолетной рукояти («как от медведя») ----------------------
SP_LABEL, SP_DARK, SP_ORANGE, SP_GRIP, SP_STEEL = (0, 0, 1, 0.5), (0, 0.5, 0.5, 1), (0.5, 0.5, 1, 0.75), \
    (0.5, 0.75, 0.75, 1), (0.75, 0.75, 1, 1)
SP_R, SP_X0, SP_X1, SP_Z = 1.55, -3.6, 5.0, 1.5          # баллон: радиус, торцы по X, ось на высоте Z


def tex_sprayer():
    """Бумажная этикетка по окружности баллона (выцветшая, облезлая), чёрный полимер рамы и рычага,
    оранжевая предохранительная чека, рифлёная рукоять, сталь хомутов."""
    import texgen as T
    s = 101
    # Этикетка лежащего баллона читается вдоль оси: рисуем в транспонированных координатах (столбцы — длина
    # 4.5 ед., строки — окружность), потом транспонируем в раскладку цилиндра (u — окружность, v — длина).
    # Плотность почти квадратная (9.8 ед. / 512 пикс ≈ 4.5 ед. / 256 пикс) — без сжатия.
    lab = T.weathered_paint(256, 512, (214, 204, 170), s, wear=0.6, rims=("left", "right"), rim_width=18, hits=3,
                            rust=0.0, grime=1.2, fade=1.0, gloss_paint=0.1, primer=(120, 116, 104))
    for cy in (128, 384):   # две стороны баллона
        T.band(lab, cy - 92, cy - 80, (176, 40, 32), s + cy)
        T.stencil_text(lab, "РГ-2 «ТУМАН»", T.fit_font("РГ-2 «ТУМАН»", 230, 40), (128, cy - 44), (30, 30, 30),
                       seed=s + cy, bridges=False)
        T.stencil_text(lab, "РАСПЫЛИТЕЛЬ ГАЗОВЫЙ", T.fit_font("РАСПЫЛИТЕЛЬ ГАЗОВЫЙ", 230, 22, "SemiBold Condensed"),
                       (128, cy), (40, 40, 40), seed=s + cy + 1, bridges=False, alpha=0.9)
        T.stencil_text(lab, "НЕ НАГРЕВАТЬ ВЫШЕ 50 °С", T.fit_font("НЕ НАГРЕВАТЬ ВЫШЕ 50 °С", 230, 15, "SemiBold Condensed"),
                       (128, cy + 34), (90, 30, 26), seed=s + cy + 2, bridges=False, alpha=0.85)
        T.stencil_text(lab, "НЕ ВСКРЫВАТЬ  НЕ НАПРАВЛЯТЬ НА ЛЮДЕЙ",
                       T.fit_font("НЕ ВСКРЫВАТЬ  НЕ НАПРАВЛЯТЬ НА ЛЮДЕЙ", 230, 13, "SemiBold Condensed"),
                       (128, cy + 54), (90, 30, 26), seed=s + cy + 3, bridges=False, alpha=0.85)
    lab = {"rgb": lab["rgb"].transpose(1, 0, 2)[::-1], "height": lab["height"].T[::-1], "gloss": lab["gloss"].T[::-1]}
    for k in lab:   # сторона u 0..0.5 (левый бок) — повернуть на 180°, чтобы читалась и с другого бока
        arr = lab[k].copy()
        arr[:, :256] = arr[::-1, :256][:, ::-1]
        lab[k] = arr
    dark = T.weathered_paint(256, 256, (34, 35, 36), s + 1, wear=0.5, hits=2, rust=0, grime=0.9, gloss_paint=0.2,
                             primer=(70, 70, 70))
    orange = T.weathered_paint(256, 128, (222, 110, 30), s + 2, wear=0.5, hits=2, rust=0, grime=0.7, gloss_paint=0.3,
                               primer=(160, 150, 130))
    grip = T.weathered_paint(128, 128, (32, 32, 33), s + 3, wear=0.2, hits=0, rust=0, grime=1.0, gloss_paint=0.1)
    for y in range(0, 128, 6):                                   # рифление рукояти
        grip["rgb"][y:y + 2] *= 0.7
        grip["height"][y:y + 2] -= 0.08
    steel = T.weathered_paint(128, 128, (140, 142, 140), s + 4, wear=0, hits=0, rust=0.5, grime=0.6, gloss_paint=0.55)
    color, nrm = Image.new("RGB", (512, 512)), Image.new("RGBA", (512, 512))
    for layer, rect in ((lab, SP_LABEL), (dark, SP_DARK), (orange, SP_ORANGE), (grip, SP_GRIP), (steel, SP_STEEL)):
        paste_region(color, T.to_image(layer), rect)
        paste_region(nrm, T.normal_image(layer["height"], layer["gloss"], 4), rect)
    return color, nrm


def tex_sprayer_tank():
    """Корпус баллона: белая эмаль со сколами до стали и грязью — в игре тонируется в цвет газа ($color2)."""
    import texgen as T
    can = T.weathered_paint(256, 256, (228, 228, 224), 111, wear=0.9, rims=("top", "bottom"), rim_width=18, hits=4,
                            rust=0.5, grime=1.0, gloss_paint=0.35)
    return T.to_image(can), T.normal_image(can["height"], can["gloss"], 4)


def model_sprayer():
    """Распылитель (+X — сопло): аэрозольный баллон лёжа вдоль ствола (материал sprayer_tank, тонируется
    в цвет газа), бумажная этикетка, донце и купол, клапан с распылительной головкой и рычагом нажима,
    оранжевая предохранительная чека; полимерная рама с пистолетной рукоятью, скобой и спуском; тяга
    от спуска к рычагу вдоль левого бока; два стальных хомута."""
    mat, tank = "sprayer", "sprayer_tank"
    full = (0, 0, 1, 1)
    ax = (1, 0, 0)
    c0 = (SP_X0, 0, SP_Z)
    L_ = SP_X1 - SP_X0
    parts = [
        cylinder(tank, full, SP_R, L_, 30, base=c0, axis=ax, caps=False),
        ellipsoid(tank, full, (SP_R, SP_R, 0.9), center=c0, part="top", seg=30, rings=6, axis=(-1, 0, 0)),
        ellipsoid(tank, full, (SP_R, SP_R, 1.1), center=(SP_X1, 0, SP_Z), part="top", seg=30, rings=6, axis=ax),
        cylinder(mat, SP_LABEL, SP_R + 0.015, 4.5, 30, base=(-1.9, 0, SP_Z), axis=ax, caps=False, fit=False),
        torus(mat, SP_STEEL, SP_R - 0.05, 0.1, center=(SP_X0, 0, SP_Z), axis=ax, seg=30, side=5),     # завальцовка донца
        torus(mat, SP_STEEL, 0.55, 0.12, center=(SP_X1 + 1.05, 0, SP_Z), axis=ax, seg=20, side=5),    # клапанная чашка
        cylinder(mat, SP_DARK, 0.42, 0.7, 16, base=(SP_X1 + 1.0, 0, SP_Z), axis=ax, cap_rect=SP_DARK),  # шток
        box(mat, SP_DARK, (SP_X1 + 1.6, -0.55, SP_Z - 0.55), (SP_X1 + 2.5, 0.55, SP_Z + 0.65)),          # головка
        cylinder(mat, SP_STEEL, 0.16, 0.25, 10, base=(SP_X1 + 2.5, 0, SP_Z + 0.05), axis=ax, cap_rect=SP_DARK),  # сопло
        # рычаг нажима над головкой и чека
        box(mat, SP_DARK, (SP_X1 + 0.3, -0.35, SP_Z + 0.65), (SP_X1 + 2.6, 0.35, SP_Z + 0.85),
            M=rot_axis((0, 1, 0), math.radians(8)), t=(0, 0, 0.2)),
        box(mat, SP_ORANGE, (SP_X1 + 1.0, -0.62, SP_Z + 0.85), (SP_X1 + 1.5, 0.62, SP_Z + 1.25)),
        torus(mat, SP_ORANGE, 0.32, 0.07, center=(SP_X1 + 1.25, 0.95, SP_Z + 1.05), axis=(0, 1, 0), seg=14, side=4),
        # рама под баллоном
        box(mat, SP_DARK, (-3.2, -0.5, -0.45), (4.3, 0.5, 0.15)),
        box(mat, SP_DARK, (3.6, -0.5, 0.15), (4.3, 0.5, SP_Z - 0.2)),
        # рукоять, скоба, спуск
        box(mat, SP_GRIP, (-1.0, -0.65, -4.6), (1.0, 0.65, 0.0), M=rot_axis((0, 1, 0), math.radians(15)), t=(-2.0, 0, -0.4)),
        torus_arc(mat, SP_DARK, 0.95, 0.12, math.pi, 2 * math.pi, center=(0.3, 0, -0.55),
                  M2=rot_axis((1, 0, 0), math.pi / 2), seg=12, side=5),
        box(mat, SP_ORANGE, (-0.05, -0.15, -1.3), (0.3, 0.15, -0.45)),
        # тяга от спуска к рычагу по левому боку
        tube(mat, SP_STEEL, [(0.2, 0.62, -0.3), (1.0, 1.0, 0.2), (4.6, 1.0, 0.6), (SP_X1 + 0.9, 0.62, SP_Z + 0.75)], 0.08, 6),
    ]
    for x in (-2.7, 3.2):   # хомуты баллона к раме
        parts.append(torus(mat, SP_STEEL, SP_R + 0.06, 0.1, center=(x, 0, SP_Z), axis=ax, seg=30, side=5))
        parts.append(box(mat, SP_STEEL, (x - 0.15, -0.3, -0.1), (x + 0.15, 0.3, 0.1)))
    m = combine(*parts)
    phys = box("phys", SP_DARK, (-4.6, -1.6, -5.0), (7.6, 1.6, 3.1))
    return m, phys, [("root", -1, (0, 0, 0))], 1.5, "metal", None


def tex_vent(outlet):
    S = 512
    img = Image.new("RGB", (S, S))
    col = (200, 70, 44) if outlet else (44, 110, 200)
    flange = metal((S, 256), tuple(int(c * 0.35 + 120 * 0.65) for c in col), 81 + outlet)   # окрашенный металл
    wear(flange, 81 + outlet, 60)
    paste_region(img, flange, R_PAINT)
    paste_region(img, metal((256, 256), (70, 72, 76), 82), R_DARK)
    paste_region(img, metal((256, 128), (100, 104, 108), 83), R_HOUSING)
    paste_region(img, label_plate("EXHAUST" if outlet else "INTAKE", 7.5, col, (245, 245, 240)), R_PLATE)
    return img


def tex_nozzle():
    S = 256
    img = Image.new("RGB", (S, S))
    body = noise_img((S, 154), (40, 40, 42), 6, 91)
    d = ImageDraw.Draw(body)
    for x in range(0, S, 16):
        d.rectangle([x, 0, x + 6, 154], fill=(28, 28, 30))
    paste_region(img, body, (0, 0, 1, 0.6))
    paste_region(img, metal((256, 102), (176, 150, 80), 92), (0, 0.6, 1, 1))
    return img


def tex_fan_blower():
    return tex_fan((206, 124, 40), "BLOWER  >>>", (30, 30, 30), 44)


def tex_emitter():
    S = 512
    img = Image.new("RGB", (S, S))
    body = noise_img((S, 320), (70, 92, 112), 8, 71)
    d = ImageDraw.Draw(body)
    for k in range(2):
        cx = S * (0.25 + 0.5 * k)
        text_centered(d, (cx - 120, 100, cx + 120, 170), "GAS OUT", font("impact.ttf", 52), (240, 240, 235))
    stripes(body, (0, 280, S, 320))
    wear(body, 71, 100)
    paste_region(img, face_front(body), R_BODY)
    paste_region(img, metal((256, 192), (130, 132, 136), 72), R_METAL)
    paste_region(img, metal((256, 192), (90, 92, 96), 73), R_CAP)
    return img


def save_texture(name, img, envmap=True, vmt_extra=None):
    """Цвет → VTF через vtex + VMT. vmt_extra — готовые строки параметров VMT (карта нормалей, phong);
    с ними штатный слабый envmap не добавляется (его задаёт vmt_extra)."""
    src = os.path.join(GAME, "materialsrc", "models", "aether")
    os.makedirs(src, exist_ok=True)
    tga = os.path.join(src, name + ".tga")
    img.convert("RGBA" if img.mode == "RGBA" else "RGB").save(tga)   # RGBA — альфа для $translucent
    r = subprocess.run([os.path.join(GMOD, "bin", "vtex.exe"), "-game", GAME, "-nopause", "-quiet", tga],
                       capture_output=True, text=True, timeout=300)
    if "SUCCESS" not in r.stdout:
        raise RuntimeError(f"vtex failed for {name}: {r.stdout[-1500:]}")
    os.makedirs(os.path.join(BUILD, "tex"), exist_ok=True)
    img.convert("RGB").save(os.path.join(BUILD, "tex", name + ".png"))   # для иконок
    dst = os.path.join(ADDON, "materials", "models", "aether")
    os.makedirs(dst, exist_ok=True)
    shutil.move(os.path.join(GAME, "materials", "models", "aether", name + ".vtf"), os.path.join(dst, name + ".vtf"))
    vmt = ['"VertexLitGeneric"', "{", f'\t"$basetexture" "models/aether/{name}"']
    if vmt_extra:
        vmt += ["\t" + line for line in vmt_extra]
    elif envmap:
        vmt += ['\t"$envmap" "env_cubemap"', '\t"$envmaptint" "[.06 .06 .06]"']
    vmt += ["}"]
    with open(os.path.join(dst, name + ".vmt"), "w", newline="\n") as f:
        f.write("\n".join(vmt) + "\n")


def save_normal(name, rgba):
    """Карта нормалей (RGBA: нормаль + маска блеска в альфе) → VTF через vtex с флагом normal
    (без гамма-коррекции мипов; альфа → DXT5). Только VTF, без VMT: на неё ссылается $bumpmap."""
    src = os.path.join(GAME, "materialsrc", "models", "aether")
    os.makedirs(src, exist_ok=True)
    tga = os.path.join(src, name + ".tga")
    rgba.convert("RGBA").save(tga)
    with open(os.path.join(src, name + ".txt"), "w", newline="\n") as f:
        f.write('"normal" "1"\n')
    r = subprocess.run([os.path.join(GMOD, "bin", "vtex.exe"), "-game", GAME, "-nopause", "-quiet", tga],
                       capture_output=True, text=True, timeout=300)
    if "SUCCESS" not in r.stdout:
        raise RuntimeError(f"vtex failed for {name}: {r.stdout[-1500:]}")
    dst = os.path.join(ADDON, "materials", "models", "aether")
    os.makedirs(dst, exist_ok=True)
    shutil.move(os.path.join(GAME, "materials", "models", "aether", name + ".vtf"), os.path.join(dst, name + ".vtf"))


def phong_vmt(normal):
    """Параметры VMT изношенного металла: карта нормалей, блик по маске (альфа нормалей: металл в сколах
    и латунь блестят, эмаль матовая), отражение окружения по той же маске."""
    return [f'"$bumpmap" "models/aether/{normal}"', '"$phong" "1"', '"$phongexponent" "18"',
            '"$phongboost" "1.6"', '"$phongfresnelranges" "[0.35 0.7 1]"',
            '"$envmap" "env_cubemap"', '"$normalmapalphaenvmapmask" "1"', '"$envmaptint" "[0.22 0.22 0.22]"']


def with_normal(name, pair):
    """(цвет, нормали) → сохранить карту нормалей <name>_n и вернуть (цвет, параметры VMT с phong)."""
    color, nrm = pair
    save_normal(name + "_n", nrm)
    return color, phong_vmt(name + "_n")


def textures_cylinder():
    """Классические скины (0..17) + ржавый без надписей (18) + стили CYL_STYLES по 18 газов. Узор износа
    зависит только от стиля, поэтому карта нормалей одна на стиль (берётся с первого газа)."""
    out = {f"cylinder_{g}": tex_cylinder(g) for g in GAS_ORDER}
    out["cylinder_plain"] = tex_cylinder_plain()
    for st in CYL_STYLES:
        for i, g in enumerate(GAS_ORDER):
            col, nrm = tex_cylinder_styled(g, st)
            if i == 0:
                save_normal(f"cylinder_{st}_n", nrm)
            out[f"cylinder_{st}_{g}"] = (col, phong_vmt(f"cylinder_{st}_n"))
    return out


# =============================================================================================
# Модели
# =============================================================================================
def model_grenade():
    mat = "grenade_smoke"
    m = combine(
        cylinder(mat, R_BODY, 1.7, 6.0, 28, cap_rect=R_CAP, fit=False),
        cylinder(mat, R_METAL, 1.15, 0.7, 24, base=(0, 0, 6.0), cap_rect=R_CAP),
        cylinder(mat, R_METAL, 0.55, 0.7, 16, base=(0, 0, 6.7), cap_rect=R_CAP),
        box(mat, R_METAL, (-1.92, -0.42, 3.4), (-1.66, 0.42, 7.0)),     # рычаг сзади — не закрывает надпись
        box(mat, R_METAL, (-1.92, -0.42, 7.0), (-0.5, 0.42, 7.28)),
        torus(mat, R_METAL, 0.65, 0.09, center=(0.75, 0, 7.05), axis=(0, 1, 0), seg=20, side=6),
    )
    phys = cylinder("phys", R_METAL, 1.7, 7.3, 10)
    return m, phys, [("root", -1, (0, 0, 0))], 0.6, "metal", (
        [f"grenade_{g}" for g in GAS_ORDER] + [f"grenade_{st}_{g}" for st in GRENADE_STYLES for g in GAS_ORDER])


def canister_mesh(mat):
    """Баллон 40 л: корпус, плечо, горловина, вентиль (латунь) с боковым штуцером, шток и маховик (красный)."""
    rb, rs, rm, rw = (0, 0, 1, 0.75), (0, 0.75, 0.5, 1), CYL_BRASS, CYL_WHEEL
    return combine(
        cylinder(mat, rb, 4.5, 34, 32, cap_rect=rs, fit=False),
        ellipsoid(mat, rs, (4.5, 4.5, 4.0), center=(0, 0, 34), part="top", seg=32, rings=8),
        cylinder(mat, rm, 1.3, 3.0, 20, base=(0, 0, 37.6), cap_rect=rm),
        box(mat, rm, (-1.0, -1.0, 40.5), (1.0, 1.0, 42.5)),
        cylinder(mat, rm, 0.45, 1.6, 12, base=(1.0, 0, 41.5), axis=(1, 0, 0), cap_rect=rm),
        cylinder(mat, rm, 0.25, 1.1, 10, base=(0, 0, 42.5), cap_rect=rm),
        torus(mat, rw, 1.5, 0.22, center=(0, 0, 43.5), seg=24, side=8),
        box(mat, rw, (-1.5, -0.12, 43.38), (1.5, 0.12, 43.62)),
        box(mat, rw, (-0.12, -1.5, 43.38), (0.12, 1.5, 43.62)),
        cylinder(mat, rw, 0.32, 0.3, 12, base=(0, 0, 43.35), cap_rect=rw),
    )


def model_canister():
    """Старая общая модель (скины 0..17 по газам + 18 без надписей) — для дупов и сохранений до 0.12."""
    mat = "cylinder_smoke"   # = первая строка $texturegroup, иначе скины не подменяют материал
    m = canister_mesh(mat)
    phys = cylinder("phys", (0, 0, 1, 0.75), 4.5, 43.8, 10)
    skins = [f"cylinder_{g}" for g in GAS_ORDER] + ["cylinder_plain"]
    return m, phys, [("root", -1, (0, 0, 0))], 40, "metal", skins


CYL_SKINS = ("su", "nato", "modern", "classic", "plain")   # = стили 1..5 в Lua: скин = стиль − 1


def cylinder_skin_materials(gas):
    out = []
    for st in CYL_SKINS:
        out.append("cylinder_plain" if st == "plain" else f"cylinder_{gas}" if st == "classic" else f"cylinder_{st}_{gas}")
    return out


def model_canister_gas(gas):
    """Модель баллона одного газа (models/aether/gas_cylinder_<газ>.mdl): ровно пять скинов — СССР, НАТО,
    современный, классический, без знаков. Меню «Скин» в игре показывает только их."""
    skins = cylinder_skin_materials(gas)
    m = canister_mesh(skins[0])
    phys = cylinder("phys", (0, 0, 1, 0.75), 4.5, 43.8, 10)
    return m, phys, [("root", -1, (0, 0, 0))], 40, "metal", skins


def model_propane():
    mat = "propane"
    m = combine(
        double_sided(cylinder(mat, R_METAL, 4.6, 1.6, 28, caps=False)),
        ellipsoid(mat, R_METAL, (5.6, 5.6, 2.0), center=(0, 0, 3.2), part="bottom", seg=32, rings=6),
        cylinder(mat, R_BODY, 5.6, 9.3, 32, base=(0, 0, 3.2), caps=False, fit=False),
        ellipsoid(mat, R_METAL, (5.6, 5.6, 2.4), center=(0, 0, 12.5), part="top", seg=32, rings=6),
        double_sided(cylinder(mat, R_METAL, 2.7, 3.4, 24, base=(0, 0, 13.9), caps=False)),
        cylinder(mat, R_CAP, 0.7, 1.4, 12, base=(0, 0, 14.6)),
        torus(mat, R_CAP, 0.9, 0.16, center=(0, 0, 16.2), seg=18, side=6),
        cylinder(mat, R_CAP, 0.3, 1.2, 8, base=(0.5, 0, 15.3), axis=(1, 0, 0)),
    )
    phys = cylinder("phys", R_BODY, 5.6, 17.0, 10)
    return m, phys, [("root", -1, (0, 0, 0))], 15, "metal", None


def model_fan():
    mat = "fan"
    rf, rb, rm = R_PAINT, R_DARK, R_HOUSING
    parts = [
        box(mat, R_PLATE, (4.0, -10, 26.2), (4.2, 10, 27.8), fit=False),   # табличка спереди (сторона струи)
        box(mat, rf, (-4, -13, 26), (4, 13, 28)), box(mat, rf, (-4, -13, 2), (4, 13, 4)),
        box(mat, rf, (-4, -13, 4), (4, -11, 26)), box(mat, rf, (-4, 11, 4), (4, 13, 26)),
        box(mat, rf, (-7, -12.5, 0), (7, -9.5, 2)), box(mat, rf, (-7, 9.5, 0), (7, 12.5, 2)),
        cylinder(mat, rm, 4.2, 8, 24, base=(-4, 0, 15), axis=(-1, 0, 0), cap_rect=rm),
        box(mat, rf, (-4, -11, 14.5), (-3, 11, 15.5)), box(mat, rf, (-4, -0.5, 4), (-3, 0.5, 26)),
    ]
    for y in np.arange(-10, 10.01, 2.5):
        parts.append(box(mat, rb, (4.2, y - 0.15, 4), (4.5, y + 0.15, 26)))
    parts.append(box(mat, rb, (4.2, -11, 14.85), (4.5, 11, 15.15)))
    blades = [cylinder(mat, rb, 1.8, 2.5, 16, base=(-1.0, 0, 15), axis=(1, 0, 0), bone=1)]
    for k in range(5):
        M = rot_axis((1, 0, 0), k * 2 * math.pi / 5) @ rot_axis((0, 1, 0), math.radians(25))
        blades.append(box(mat, rb, (-0.15, 1.6, -1.9), (0.15, 10.4, 1.9), bone=1, M=M, t=(0.3, 0, 15)))
    m = combine(*parts, *blades)
    phys = box("phys", rf, (-12, -13, 0), (5, 13, 28))
    bones = [("root", -1, (0, 0, 0)), ("blades", 0, (0, 0, 15))]
    return m, phys, bones, 30, "metal", ["fan", "fan_blower", "fan_su", "fan_blower_su", "fan_nato", "fan_blower_nato"]


def model_vent():
    """Решётка воздуховода (впуск/выпуск): короб 16×16, фланец, жалюзи. Скины: vent_in / vent_out."""
    mat = "vent_in"
    rf, rg, rs = R_PAINT, R_DARK, R_HOUSING
    parts = [
        box(mat, R_PLATE, (1.0, -6, 8.2), (1.15, 6, 9.8), fit=False),        # табличка INTAKE / EXHAUST
        box(mat, rs, (-8, -8, -8), (0, 8, -7)), box(mat, rs, (-8, -8, 7), (0, 8, 8)),
        box(mat, rs, (-8, -8, -7), (0, -7, 7)), box(mat, rs, (-8, 7, -7), (0, 8, 7)),
        box(mat, rf, (0, -10, -10), (1, 10, -8)), box(mat, rf, (0, -10, 8), (1, 10, 10)),
        box(mat, rf, (0, -10, -8), (1, -8, 8)), box(mat, rf, (0, 8, -8), (1, 10, 8)),
        box(mat, rs, (-8.5, -7, -7), (-8, 7, 7)),
        cylinder(mat, rs, 3.0, 4.0, 18, base=(-8.5, 0, 0), axis=(-1, 0, 0), cap_rect=rs),
    ]
    for z in np.arange(-6.5, 6.6, 1.6):
        M = rot_axis((0, 1, 0), math.radians(35))
        parts.append(box(mat, rg, (-0.6, -7.2, -0.12), (0.6, 7.2, 0.12), M=M, t=(0.2, 0, z)))
    m = combine(*parts)
    phys = box("phys", rf, (-12.5, -10, -10), (1, 10, 10))
    return m, phys, [("root", -1, (0, 0, 0))], 6, "metal", ["vent_in", "vent_out", "vent_su_in", "vent_su_out",
                                                             "vent_nato_in", "vent_nato_out"]


def model_nozzle():
    """Наконечник шланга: соединитель, хвостовик под шланг, конус сопла (ось +X)."""
    mat = "nozzle"
    rb, rm = (0, 0, 1, 0.6), (0, 0.6, 1, 1)
    m = combine(
        cylinder(mat, rm, 0.9, 2.0, 16, base=(-3, 0, 0), axis=(1, 0, 0), cap_rect=rm),
        cylinder(mat, rb, 1.4, 3.0, 20, base=(-1, 0, 0), axis=(1, 0, 0), cap_rect=rm),
        cylinder(mat, rm, 1.4, 2.4, 20, base=(2, 0, 0), axis=(1, 0, 0), r_top=0.6, cap_rect=rm),
        torus(mat, rm, 1.45, 0.18, center=(2.0, 0, 0), axis=(1, 0, 0), seg=18, side=5),
    )
    phys = cylinder("phys", rb, 1.4, 7.4, 8, base=(-3, 0, 0), axis=(1, 0, 0))
    return m, phys, [("root", -1, (0, 0, 0))], 1.5, "metal", None


# --- Антидоты: автошприц с атропином, ИПП, промывка глаз, кислородный баллончик ------------------------
# Атлас как у фаера: корпус R_BODY (по окружности), торцы/металл R_METAL, колпачок R_CAP.
def tex_wrap_item(paint, lines, ink, radius, length, seed, along=False, bands=(), cap=(40, 40, 40),
                  metal_col=(140, 142, 140), wear=0.6, rust=0.2, gloss=0.25, primer=None):
    """Корпус-цилиндр с износом и надписями. along=True — надпись вдоль оси (тонкие трубки: автошприц),
    иначе — по окружности (флакон, баллончик). lines — [(текст, размер, начертание)].
    bands — цветные полосы [(доля длины от, до, цвет)]. Возвращает (цвет, нормали+блеск)."""
    import texgen as T
    W, H = 512, 320
    if along:
        body = T.weathered_paint(H, W, paint, seed, wear=wear, rims=("left", "right"), rim_width=12, hits=3,
                                 rust=rust, grime=0.8, gloss_paint=gloss, primer=primer or T.PRIMER)
        for a, b, col in bands:
            m = np.zeros((W, H))
            m[:, int(a * H):int(b * H)] = 1
            body["rgb"] = body["rgb"] * (1 - m[..., None]) + np.array(col, float) * m[..., None]
        sq = (length / H) / (2 * math.pi * radius / W)
        for cy in (128, 384):
            y = cy - 12 * (len(lines) - 1)
            for text, size, var in lines:
                T.stencil_text(body, text, T.fit_font(text, int(H * 0.8), size, var), (H // 2, y), ink, seed=seed + cy + y,
                               squash=sq, bridges=False, alpha=0.9)
                y += int(size * 1.1)
        body = {k: (body[k].transpose(1, 0, 2) if k == "rgb" else body[k].T)[::-1] for k in ("rgb", "height", "gloss")}
        body = {k: np.roll(v, -128, axis=1) for k, v in body.items()}
    else:
        sq = (2 * math.pi * radius / W) / (length / H)
        body = T.weathered_paint(W, H, paint, seed, wear=wear, rims=("top", "bottom"), rim_width=16, hits=4,
                                 rust=rust, grime=0.9, gloss_paint=gloss, primer=primer or T.PRIMER)
        for a, b, col in bands:
            T.band(body, a * H, b * H, col, seed)
        for k in range(2):
            cx = W * (0.25 + 0.5 * k)
            y = H * 0.45 - 20 * (len(lines) - 1)
            for text, size, var in lines:
                T.stencil_text(body, text, T.fit_font(text, W // 3, size, var), (cx, y), ink, seed=seed + k * 7 + int(y),
                               squash=sq, bridges=False, alpha=0.9)
                y += size * 1.15 / sq
        body = {k: np.roll(v, -W // 4, axis=1) for k, v in body.items()}
    pr = primer or T.PRIMER
    ends = T.weathered_paint(256, 192, metal_col, seed + 10, wear=0.3, hits=1, rust=rust, grime=0.6, gloss_paint=0.55,
                             primer=pr)
    capl = T.weathered_paint(256, 192, cap, seed + 20, wear=0.4, hits=1, rust=0, grime=0.6, gloss_paint=0.3, primer=pr)
    for y in range(0, 192, 10):
        capl["rgb"][y:y + 3] *= 0.8
        capl["height"][y:y + 3] -= 0.06
    color, nrm = Image.new("RGB", (512, 512)), Image.new("RGBA", (512, 512))
    for layer, rect in ((body, R_BODY), (ends, R_METAL), (capl, R_CAP)):
        paste_region(color, T.to_image(layer), rect)
        paste_region(nrm, T.normal_image(layer["height"], layer["gloss"], 4), rect)
    return color, nrm


def tex_atropine():
    return tex_wrap_item((78, 86, 60), [("АТРОПИН", 30, "Bold Condensed"), ("АВТОШПРИЦ  1 МЛ", 15, "SemiBold Condensed")],
                         (226, 222, 196), 0.55, 5.2, 301, along=True, bands=((0.02, 0.1, (214, 180, 40)),),
                         cap=(214, 180, 40), metal_col=(150, 150, 146))


def model_atropine():
    """Автошприц (ось Z): корпус, жёлтый колпачок со стороны иглы снизу, серый предохранитель сверху."""
    mat = "antidote_atropine"
    m = combine(
        cylinder(mat, R_BODY, 0.55, 5.2, 20, base=(0, 0, 0.6), cap_rect=R_METAL, fit=False),
        cylinder(mat, R_CAP, 0.6, 0.6, 20, base=(0, 0, 0), r_top=0.55, cap_rect=R_CAP),
        cylinder(mat, R_METAL, 0.42, 0.7, 16, base=(0, 0, 5.8), cap_rect=R_METAL),
        torus(mat, R_METAL, 0.45, 0.07, center=(0, 0, 6.5), axis=(1, 0, 0), seg=12, side=4),   # кольцо предохранителя
    )
    phys = cylinder("phys", R_BODY, 0.6, 6.6, 8)
    return m, phys, [("root", -1, (0, 0, 0))], 0.3, "plastic", ["antidote_atropine", "antidote_atropine_nato"]


def tex_eyewash():
    return tex_wrap_item((226, 228, 222), [("ПРОМЫВКА", 30, "Bold Condensed"), ("ГЛАЗ", 30, "Bold Condensed"),
                                           ("РАСТВОР NaCl 0,9 %", 13, "SemiBold Condensed")],
                         (40, 70, 140), 1.0, 3.6, 311, bands=((0.08, 0.16, (40, 90, 170)),), cap=(40, 90, 170),
                         metal_col=(220, 222, 218), wear=0.2, rust=0.0, gloss=0.5, primer=(200, 200, 196))


def model_eyewash():
    """Пластиковый флакон (ось Z): корпус, плечо, синий колпачок с носиком."""
    mat = "antidote_eyewash"
    m = combine(
        cylinder(mat, R_BODY, 1.0, 3.6, 22, cap_rect=R_METAL, fit=False),
        cylinder(mat, R_METAL, 1.0, 0.6, 22, base=(0, 0, 3.6), r_top=0.45, caps=False),
        cylinder(mat, R_CAP, 0.5, 0.6, 18, base=(0, 0, 4.2), cap_rect=R_CAP),
        cylinder(mat, R_CAP, 0.18, 0.6, 10, base=(0, 0, 4.8), r_top=0.08, cap_rect=R_CAP),
    )
    phys = cylinder("phys", R_BODY, 1.0, 5.4, 8)
    return m, phys, [("root", -1, (0, 0, 0))], 0.3, "plastic", ["antidote_eyewash", "antidote_eyewash_nato"]


def tex_oxygen():
    # ГОСТ 949-73: кислород — голубой баллон, чёрная надпись
    return tex_wrap_item((96, 150, 196), [("КИСЛОРОД", 34, "Bold Condensed"), ("МЕДИЦИНСКИЙ", 16, "SemiBold Condensed")],
                         (20, 20, 22), 1.3, 7.0, 321, cap=(30, 30, 32), metal_col=(150, 124, 66), wear=0.7, rust=0.4)


def model_oxygen():
    """Карманный кислородный баллончик (ось Z): корпус, плечо, латунный вентиль, чёрная маска-колпачок сверху."""
    mat = "antidote_oxygen"
    m = combine(
        cylinder(mat, R_BODY, 1.3, 7.0, 24, cap_rect=R_METAL, fit=False),
        ellipsoid(mat, R_METAL, (1.3, 1.3, 0.8), center=(0, 0, 7.0), part="top", seg=24, rings=5),
        cylinder(mat, R_METAL, 0.35, 0.6, 12, base=(0, 0, 7.7), cap_rect=R_METAL),
        cylinder(mat, R_CAP, 1.0, 0.9, 20, base=(0, 0, 8.3), r_top=0.75, cap_rect=R_CAP),   # маска-раструб
    )
    phys = cylinder("phys", R_BODY, 1.3, 9.2, 8)
    return m, phys, [("root", -1, (0, 0, 0))], 0.6, "metal", ["antidote_oxygen", "antidote_oxygen_nato"]


def tex_decon():
    """ИПП: прорезиненный оливковый пакет (корпус и торцы), белая табличка с надписью (R_CAP)."""
    import texgen as T
    s = 331
    pouch = T.weathered_paint(512, 320, (84, 92, 62), s, wear=0.3, hits=2, rust=0, grime=1.0, gloss_paint=0.2,
                              primer=(110, 116, 90))
    pouch["height"] = pouch["height"] + T.fbm(512, 320, s + 1, ((24, 0.7), (8, 0.3))) * 0.015   # складки
    edge = T.weathered_paint(256, 192, (70, 78, 52), s + 2, wear=0.2, hits=1, rust=0, grime=1.0, gloss_paint=0.2,
                             primer=(110, 116, 90))
    lab = T.weathered_paint(256, 192, (222, 218, 200), s + 3, wear=0.3, hits=1, rust=0, grime=0.8, gloss_paint=0.1,
                            primer=(190, 186, 170))
    for text, y, size, var in (("ИПП-8", 60, 64, "Bold Condensed"), ("ПРОТИВОХИМИЧЕСКИЙ", 116, 22, "SemiBold Condensed"),
                               ("ПАКЕТ", 146, 22, "SemiBold Condensed")):
        T.stencil_text(lab, text, T.fit_font(text, 230, size, var), (128, y), (30, 30, 30), seed=s + y, bridges=False)
    color, nrm = Image.new("RGB", (512, 512)), Image.new("RGBA", (512, 512))
    # табличка лежит на верхней грани: UV грани повёрнуты на 90° относительно картинки
    lab = {k: np.rot90(v, 1).copy() for k, v in lab.items() if k in ("rgb", "height", "gloss")}
    for layer, rect in ((pouch, R_BODY), (edge, R_METAL), (lab, R_CAP)):
        paste_region(color, T.to_image(layer), rect)
        paste_region(nrm, T.normal_image(layer["height"], layer["gloss"], 4), rect)
    return color, nrm


def model_decon():
    """ИПП: плоский пакет 4.2 × 2.8 × 1.0, прошитый кант, табличка сверху, отрывной язычок."""
    mat = "antidote_decon"
    m = combine(
        box(mat, R_BODY, (-2.1, -1.4, 0), (2.1, 1.4, 1.0)),
        box(mat, R_METAL, (-2.25, -1.55, 0.4), (2.25, 1.55, 0.6)),          # прошитый кант
        box(mat, R_CAP, (-1.5, -1.0, 1.0), (1.5, 1.0, 1.03), fit=False),    # табличка
        box(mat, R_METAL, (2.25, -0.4, 0.42), (2.75, 0.4, 0.58)),            # язычок
    )
    phys = box("phys", R_BODY, (-2.25, -1.55, 0), (2.75, 1.55, 1.05))
    return m, phys, [("root", -1, (0, 0, 0))], 0.3, "rubber", ["antidote_decon", "antidote_decon_nato"]


# --- Виды предметов: СССР / НАТО / классика (кроме баллонов — у них свои пять видов) -------------------------
# Порядок групп скинов в моделях: СССР, НАТО, классика (= LOOK_ORDER, Lua: AetherGas.ItemLookIndex).
LOOK_ORDER = ("su", "nato", "classic")
FLARE_EN = {"signal_red": "RED", "signal_green": "GREEN", "signal_yellow": "YELLOW", "signal_violet": "VIOLET",
            "signal_orange": "ORANGE"}


def tex_flare_nato(gas):
    """Ручной дымовой сигнал армии США (в духе M18): светло-зелёный металлический корпус, чёрный трафарет
    вдоль, цветные полосы у головки и дна, тёмная головка, колпачок цвета дыма."""
    col = GAS_GLOW[gas]
    return tex_wrap_item((112, 128, 92), [("SMOKE " + FLARE_EN[gas], 30, "Bold Condensed"),
                                          ("HAND SIGNAL  M18  LOT 87-A", 13, "SemiBold Condensed")],
                         (22, 22, 22), 0.75, 8.6, 401, along=True,
                         bands=((0.02, 0.12, col), (0.9, 0.97, col)), cap=tuple(int(c * 0.8) for c in col),
                         metal_col=(46, 42, 38), wear=0.6, rust=0.5, primer=(150, 146, 92))


def tex_antidote_nato(kind):
    if kind == "atropine":
        return tex_wrap_item((88, 96, 66), [("ATROPINE", 30, "Bold Condensed"), ("AUTO-INJECTOR  2 MG", 14, "SemiBold Condensed")],
                             (20, 20, 20), 0.55, 5.2, 411, along=True, bands=((0.02, 0.1, (40, 120, 60)),),
                             cap=(40, 120, 60), metal_col=(150, 150, 146), primer=(150, 146, 92))
    if kind == "eyewash":
        return tex_wrap_item((228, 228, 222), [("EYE WASH", 30, "Bold Condensed"), ("STERILE SALINE 0.9%", 14, "SemiBold Condensed")],
                             (30, 30, 30), 1.0, 3.6, 421, bands=((0.08, 0.16, (40, 120, 60)),), cap=(40, 120, 60),
                             metal_col=(220, 222, 218), wear=0.2, rust=0.0, gloss=0.5, primer=(200, 200, 196))
    if kind == "oxygen":   # медицинский кислород в США — зелёный баллон
        return tex_wrap_item((48, 112, 64), [("OXYGEN", 34, "Bold Condensed"), ("U.S.P.  MEDICAL", 16, "SemiBold Condensed")],
                             (236, 236, 228), 1.3, 7.0, 431, cap=(30, 30, 32), metal_col=(150, 124, 66), wear=0.7,
                             rust=0.4, primer=(150, 146, 92))
    # decon: набор M291 — оливковый пакет, чёрный трафарет на табличке
    import texgen as T
    s = 441
    pouch = T.weathered_paint(512, 320, (78, 82, 58), s, wear=0.3, hits=2, rust=0, grime=1.0, gloss_paint=0.2,
                              primer=(110, 112, 84))
    pouch["height"] = pouch["height"] + T.fbm(512, 320, s + 1, ((24, 0.7), (8, 0.3))) * 0.015
    edge = T.weathered_paint(256, 192, (64, 68, 48), s + 2, wear=0.2, hits=1, rust=0, grime=1.0, gloss_paint=0.2,
                             primer=(110, 112, 84))
    lab = T.weathered_paint(256, 192, (96, 102, 74), s + 3, wear=0.3, hits=1, rust=0, grime=0.8, gloss_paint=0.1,
                            primer=(120, 124, 94))
    for text, y, size, var in (("M291", 60, 64, "Bold Condensed"), ("SKIN DECONTAMINATING", 116, 22, "SemiBold Condensed"),
                               ("KIT", 146, 22, "SemiBold Condensed")):
        T.stencil_text(lab, text, T.fit_font(text, 230, size, var), (128, y), (20, 20, 20), seed=s + y, bridges=False)
    lab = {k: np.rot90(v, 1).copy() for k, v in lab.items() if k in ("rgb", "height", "gloss")}
    color, nrm = Image.new("RGB", (512, 512)), Image.new("RGBA", (512, 512))
    for layer, rect in ((pouch, R_BODY), (edge, R_METAL), (lab, R_CAP)):
        paste_region(color, T.to_image(layer), rect)
        paste_region(nrm, T.normal_image(layer["height"], layer["gloss"], 4), rect)
    return color, nrm


# --- Виды гранат: СССР (оливковая РДГ, трафарет, цветная полоса газа) и НАТО (M18: корпус по типу
# боеприпаса, полосы по ОВ/цвету дыма). Классика — tex_grenade (до 0.12). Порядок скинов модели:
# классика 0..17, СССР 18..35, НАТО 36..53 (aether_grenade.lua: LOOK_BASE).
GRENADE_STYLES = ("su", "nato")


def tex_grenade_su(gas):
    paint, name, ink, band, sub = GOST[gas]
    band = band or paint
    return tex_wrap_item((80, 86, 58), [(name, 62, "Bold Condensed"), (sub, 22, "SemiBold Condensed"),
                                        ("РДГ  ПАРТ. 12-86", 18, "SemiBold Condensed")],
                         (228, 224, 200), 1.7, 6.0, 511, bands=((0.06, 0.16, band),), cap=(60, 64, 46),
                         metal_col=(120, 122, 116), wear=0.7, rust=0.3, primer=(120, 118, 90))


def tex_grenade_nato(gas):
    body, shoulder, name, sub, ink, stripes = NATO[gas]
    if body == OD:                                   # промышленные газы — светло-зелёный корпус гранаты
        body, ink = LGREEN, (20, 20, 20)
    bands = [(0.05 + 0.1 * i, 0.11 + 0.1 * i, c) for i, c in enumerate(stripes)]
    if not stripes and shoulder not in (LGREEN, GREY):
        bands = [(0.05, 0.11, shoulder)]
    return tex_wrap_item(body, [(name, 54, "Bold Condensed"), ("GRENADE  HAND", 22, "SemiBold Condensed"),
                                (sub, 17, "SemiBold Condensed")],
                         ink, 1.7, 6.0, 521, bands=bands, cap=(70, 72, 66), metal_col=(130, 132, 128),
                         wear=0.5, rust=0.2, primer=(150, 146, 92))


def textures_grenade():
    """Скины гранаты: классика, СССР, НАТО × 18 газов. Карта нормалей — одна на вид; цвет СССР/НАТО — 256 px
    (граната маленькая, 36 текстур по 512 добавили бы ~6 МБ)."""
    out = {f"grenade_{g}": tex_grenade(g) for g in GAS_ORDER}
    for st, fn in (("su", tex_grenade_su), ("nato", tex_grenade_nato)):
        for i, g in enumerate(GAS_ORDER):
            col, nrm = fn(g)
            if i == 0:
                save_normal(f"grenade_{st}_n", nrm.resize((256, 256), Image.LANCZOS))
            out[f"grenade_{st}_{g}"] = (col.resize((256, 256), Image.LANCZOS), phong_vmt(f"grenade_{st}_n"))
    return out


ANTIDOTE_TEX = {"atropine": tex_atropine, "eyewash": tex_eyewash, "oxygen": tex_oxygen, "decon": tex_decon}


def textures_antidote(kind):
    out = {f"antidote_{kind}": with_normal(f"antidote_{kind}", ANTIDOTE_TEX[kind]())}
    out[f"antidote_{kind}_nato"] = with_normal(f"antidote_{kind}_nato", tex_antidote_nato(kind))
    return out


def stencil_plate(text, aspect, paint, ink, seed, primer=None, sub=None):
    """Табличка-трафарет на крашеном металле (натягивается на регион R_PLATE целиком)."""
    import texgen as T
    w = 640
    h = max(32, int(w / aspect))
    pl = T.weathered_paint(w, h, paint, seed, wear=0.6, rims=("top", "bottom", "left", "right"), rim_width=6, hits=2,
                           rust=0.4, grime=0.8, primer=primer or T.PRIMER)
    T.stencil_text(pl, text, T.fit_font(text, int(w * 0.9), int(h * 0.75)), (w // 2, h // 2), ink, seed=seed)
    return pl


def _layers_to_atlas(layers):
    """[(слой texgen, регион)] → (цвет, нормали+блеск) 512×512."""
    import texgen as T
    color, nrm = Image.new("RGB", (512, 512)), Image.new("RGBA", (512, 512))
    for layer, rect in layers:
        paste_region(color, T.to_image(layer), rect)
        paste_region(nrm, T.normal_image(layer["height"], layer["gloss"], 4), rect)
    return color, nrm


def tex_fan_styled(style, blower):
    """Вентилятор / воздуходувка: СССР — серо-зелёная эмаль, табличка «ВЕНТИЛЯТОР ВЫТЯЖНОЙ» / «ВОЗДУХОДУВКА»;
    НАТО — олива, трафарет «EXHAUST FAN» / «BLOWER, AXIAL». Износ, ржавые потёки, тёмная решётка и мотор."""
    import texgen as T
    s = (501 if style == "su" else 511) + (5 if blower else 0)
    if style == "su":
        paint = (176, 116, 44) if blower else (96, 110, 98)
        text, ink, prim = ("ВОЗДУХОДУВКА  >>>" if blower else "ВЕНТИЛЯТОР ВЫТЯЖНОЙ"), (232, 228, 206), T.PRIMER
    else:
        paint = (150, 120, 52) if blower else (78, 82, 58)
        text, ink, prim = ("BLOWER, AXIAL  >>>" if blower else "EXHAUST FAN"), (20, 20, 20), T.PRIMER_ZINC
    frame = T.weathered_paint(512, 256, paint, s, wear=1.0, rims=("top", "bottom"), rim_width=18, hits=5, rust=0.8,
                              grime=1.0, primer=prim)
    dark = T.weathered_paint(256, 256, (54, 56, 58), s + 1, wear=0.4, hits=2, rust=0.6, grime=0.8, gloss_paint=0.35,
                             primer=(70, 70, 72))
    motor = T.weathered_paint(256, 128, tuple(int(c * 0.85) for c in paint), s + 2, wear=0.8, hits=2, rust=0.7, grime=1.0,
                              primer=prim)
    for y in range(10, 120, 14):   # рёбра охлаждения мотора
        motor["rgb"][y:y + 5] *= 0.6
        motor["height"][y:y + 5] -= 0.1
    plate = stencil_plate(text, 12.5, tuple(int(c * 0.9) for c in paint), ink, s + 3, primer=prim)
    return _layers_to_atlas(((frame, R_PAINT), (dark, R_DARK), (motor, R_HOUSING), (plate, R_PLATE)))


def tex_vent_styled(style, outlet):
    """Решётка воздуховода: СССР — «ПРИТОК» (синевато-серая) / «ВЫТЯЖКА» (красно-коричневая);
    НАТО — олива с цветной полосой на табличке «INTAKE» / «EXHAUST». Цвет впуска/выпуска сохранён: читается в игре."""
    import texgen as T
    s = (521 if style == "su" else 531) + outlet
    if style == "su":
        paint = (128, 64, 50) if outlet else (78, 104, 128)
        text, ink, prim, plate_paint = ("ВЫТЯЖКА" if outlet else "ПРИТОК"), (232, 228, 206), T.PRIMER, None
    else:
        paint = (78, 82, 58)
        text, ink, prim = ("EXHAUST" if outlet else "INTAKE"), (236, 232, 210), T.PRIMER_ZINC
        plate_paint = (170, 56, 40) if outlet else (40, 90, 160)
    flange = T.weathered_paint(512, 256, paint, s, wear=1.0, rims=("top", "bottom", "left", "right"), rim_width=16,
                               hits=4, rust=0.8, grime=1.0, primer=prim)
    dark = T.weathered_paint(256, 256, (60, 62, 64), s + 1, wear=0.4, hits=2, rust=0.6, grime=0.9, gloss_paint=0.3,
                             primer=(70, 70, 72))
    duct = T.weathered_paint(256, 128, (112, 114, 112), s + 2, wear=0.3, hits=1, rust=0.6, grime=0.9, gloss_paint=0.4)
    plate = stencil_plate(text, 7.5, plate_paint or tuple(int(c * 0.9) for c in paint), ink, s + 3, primer=prim)
    return _layers_to_atlas(((flange, R_PAINT), (dark, R_DARK), (duct, R_HOUSING), (plate, R_PLATE)))


def textures_fan():
    out = {"fan": tex_fan(), "fan_blower": tex_fan_blower()}
    for st in ("su", "nato"):
        for blower in (False, True):
            name = f"fan{'_blower' if blower else ''}_{st}"
            col, nrm = tex_fan_styled(st, blower)
            if not blower:
                save_normal(f"fan_{st}_n", nrm)
            out[name] = (col, phong_vmt(f"fan_{st}_n"))
    return out


def textures_vent():
    out = {"vent_in": tex_vent(0), "vent_out": tex_vent(1)}
    for st in ("su", "nato"):
        for outlet in (0, 1):
            col, nrm = tex_vent_styled(st, outlet)
            if outlet == 0:
                save_normal(f"vent_{st}_n", nrm)
            out[f"vent_{st}_{'out' if outlet else 'in'}"] = (col, phong_vmt(f"vent_{st}_n"))
    return out


def model_flare():
    """Ручной дымовой сигнал (ось Z): гильза, колпачок-тёрка снизу с рёбрами и кольцом шнура, зажигательная
    головка сверху. Горящий конец — z = 10.2 (sh: aether_flare TIP)."""
    mat = "flare_signal_red"
    m = combine(
        cylinder(mat, R_BODY, 0.75, 8.6, 24, base=(0, 0, 0.8), cap_rect=R_CAP, fit=False),
        cylinder(mat, R_CAP, 0.86, 0.8, 24, base=(0, 0, 0), cap_rect=R_CAP),
        torus(mat, R_CAP, 0.86, 0.06, center=(0, 0, 0.25), seg=24, side=5),
        torus(mat, R_CAP, 0.86, 0.06, center=(0, 0, 0.55), seg=24, side=5),
        torus(mat, R_METAL, 0.32, 0.05, center=(0, 0, -0.35), axis=(1, 0, 0), seg=16, side=4),   # кольцо шнура
        cylinder(mat, R_METAL, 0.05, 0.1, 6, base=(0, 0, -0.05), cap_rect=R_METAL),
        cylinder(mat, R_METAL, 0.62, 0.8, 20, base=(0, 0, 9.4), r_top=0.5, cap_rect=R_METAL),
    )
    phys = cylinder("phys", R_BODY, 0.86, 10.2, 8)
    # группы вида (СССР, НАТО, классика) × 5 цветов = AetherGas.ItemLookIndex в Lua
    skins = [f"flare_{g}" for g in FLARE_ORDER] + [f"flare_nato_{g}" for g in FLARE_ORDER]
    skins += [f"flare_classic_{g}" for g in FLARE_ORDER]
    return m, phys, [("root", -1, (0, 0, 0))], 0.5, "plastic", skins


H_WOOD, H_FRONT, H_SIDE = (0, 0, 1, 0.5), (0, 0.5, 1, 0.75), (0, 0.75, 0.5, 1)
H_RUBBER, H_STEEL, H_STRAP = (0.5, 0.75, 0.75, 1), (0.75, 0.75, 0.875, 1), (0.875, 0.75, 1, 1)
OZK_PAINT, OZK_WOOD = (82, 88, 64), (138, 106, 68)


def tex_hazmat():
    """Ящик ОЗК: доски, окрашенные защитной краской (под сколами — дерево, в глубоких — тёмная древесина),
    трафареты на передней и боковой стенках («ОЗК», «Л-1», размер, количество, масса), прорезиненная ткань
    свёрнутого комплекта, сталь уголков и защёлок, брезентовые ремни и верёвочные ручки.
    Возвращает (цвет, нормали+блеск)."""
    import texgen as T
    s = 151

    def wood(w, h, seed, wear=1.0):
        layer = T.weathered_paint(w, h, OZK_PAINT, seed, wear=wear, rims=("top", "bottom", "left", "right"),
                                  rim_width=12, hits=6, rust=0.0, grime=1.1, primer=OZK_WOOD,
                                  base_metal=(96, 72, 46), gloss_paint=0.12)
        T.wood_grain(layer, seed, plank=25)
        return layer

    body = wood(512, 256, s)
    ink = (226, 222, 196)
    # передняя стенка 10 × 4.1 ед.: рисуется 312 × 128 и растягивается на регион 512 × 128
    front = wood(312, 128, s + 1)
    # защёлки закрывают u ≈ 30..60 и 250..285 — текст между ними
    T.stencil_text(front, "ОЗК", T.font(60), (156, 38), ink, seed=s + 2)
    T.stencil_text(front, "Л-1  РОСТ 3  КОМПЛ. 2", T.fit_font("Л-1  РОСТ 3  КОМПЛ. 2", 180, 22, "SemiBold Condensed"),
                   (156, 82), ink, seed=s + 3, bridges=False, alpha=0.9)
    T.stencil_text(front, "МАССА 7 КГ   1987", T.fit_font("МАССА 7 КГ   1987", 170, 16, "SemiBold Condensed"),
                   (156, 108), ink, seed=s + 5, bridges=False, alpha=0.75)
    # боковая стенка 15 × 4.1 ед.: рисуется 469 × 128, растягивается на 256 × 128; верёвочная ручка — u ≈ 165..303
    side = wood(469, 128, s + 6)
    T.stencil_text(side, "ОБЩЕВОЙСКОВОЙ", T.fit_font("ОБЩЕВОЙСКОВОЙ", 140, 30), (82, 44), ink, seed=s + 7, bridges=False)
    T.stencil_text(side, "ЗАЩИТНЫЙ КОМПЛЕКТ", T.fit_font("ЗАЩИТНЫЙ КОМПЛЕКТ", 140, 30), (388, 44), ink, seed=s + 8,
                   bridges=False)
    T.stencil_text(side, "ВЕРХ", T.font(20, "SemiBold Condensed"), (82, 96), ink, seed=s + 9, bridges=False, alpha=0.85)
    T.stencil_text(side, "НЕ КАНТОВАТЬ", T.font(20, "SemiBold Condensed"), (388, 96), ink, seed=s + 14, bridges=False,
                   alpha=0.85)
    # прорезиненная ткань: складки (крупный вытянутый шум по высоте), пыль, матовый блеск резины
    rub = T.weathered_paint(256, 256, (70, 84, 56), s + 10, wear=0.2, hits=0, rust=0.0, grime=0.8, fade=0.8,
                            gloss_paint=0.3, primer=(90, 98, 76))
    folds = T.fbm(256, 256, s + 11, ((40, 0.6), (14, 0.4)))
    rub["height"] = rub["height"] + folds * 0.07
    rub["rgb"] = rub["rgb"] * (1 + folds[..., None] * 0.05)
    steel = T.weathered_paint(128, 256, (60, 64, 50), s + 12, wear=1.4, hits=2, rust=0.8, grime=0.6,
                              primer=(110, 60, 40), gloss_paint=0.3)
    strap = T.weathered_paint(128, 256, (96, 92, 70), s + 13, wear=0, hits=0, rust=0, grime=1.2, fade=0.8,
                              gloss_paint=0.05)
    for y in range(0, 256, 4):                       # плетение брезентовой ленты
        strap["rgb"][y] *= 0.85
        strap["height"][y] -= 0.04
    color, nrm = Image.new("RGB", (512, 512)), Image.new("RGBA", (512, 512))
    for layer, rect in ((body, H_WOOD), (front, H_FRONT), (side, H_SIDE), (rub, H_RUBBER), (steel, H_STEEL),
                        (strap, H_STRAP)):
        paste_region(color, T.to_image(layer), rect)
        paste_region(nrm, T.normal_image(layer["height"], layer["gloss"], 4), rect)
    return color, nrm


def model_hazmat():
    """Деревянный армейский ящик ОЗК 16 × 11 × 5.6 (+X — передняя стенка с трафаретом): корпус и крышка,
    салазки снизу, стальные уголки, две защёлки спереди, верёвочные ручки на торцах (±Y). Ящик закрыт —
    комплект внутри; противогаза в нём нет, он надевается отдельно."""
    mat = "hazmat"
    parts = [
        box(mat, H_WOOD, (-8, -5.5, 0.35), (8, 5.5, 5.0)),                    # корпус
        box(mat, H_WOOD, (-8.12, -5.62, 5.0), (8.12, 5.62, 5.6)),             # крышка с напуском
        box(mat, H_WOOD, (-7.2, -5.5, 0), (-5.9, 5.5, 0.35)),                 # салазки
        box(mat, H_WOOD, (5.9, -5.5, 0), (7.2, 5.5, 0.35)),
        box(mat, H_FRONT, (8.0, -5.0, 0.6), (8.03, 5.0, 4.7), fit=False),     # трафарет спереди
        box(mat, H_SIDE, (-7.5, 5.5, 0.6), (7.5, 5.53, 4.7), fit=False),      # трафарет сбоку (+Y)
    ]
    for sx in (-1, 1):   # стальные уголки по вертикальным рёбрам и на углах крышки
        for sy in (-1, 1):
            x, y = sx * 8.0, sy * 5.5
            parts.append(box(mat, H_STEEL, (min(x, x + sx * 0.08) - 0.45 * (sx > 0), min(y, y + sy * 0.08) - 0.45 * (sy > 0), 0.35),
                             (max(x, x + sx * 0.08) + 0.45 * (sx < 0), max(y, y + sy * 0.08) + 0.45 * (sy < 0), 5.6)))
    for y in (-3.6, 3.6):   # защёлки: петля на крышке, скоба на корпусе
        parts.append(box(mat, H_STEEL, (8.0, y - 0.45, 3.9), (8.22, y + 0.45, 5.4)))
        parts.append(box(mat, H_STEEL, (8.1, y - 0.25, 3.5), (8.35, y + 0.25, 4.0)))
    for sy in (-1, 1):   # верёвочные ручки на торцах
        y = sy * 5.6
        parts.append(box(mat, H_WOOD, (-2.2, y - 0.2 * (sy < 0), 3.2), (-1.4, y + 0.2 * (sy > 0), 4.2)))
        parts.append(box(mat, H_WOOD, (1.4, y - 0.2 * (sy < 0), 3.2), (2.2, y + 0.2 * (sy > 0), 4.2)))
        parts.append(torus_arc(mat, H_STRAP, 1.8, 0.16, math.pi, 2 * math.pi, center=(0, y + sy * 0.2, 3.7),
                               M2=rot_axis((1, 0, 0), math.pi / 2), seg=14, side=6))
    m = combine(*parts)
    phys = box("phys", H_WOOD, (-8.2, -5.8, 0), (8.4, 5.8, 5.6))
    return m, phys, [("root", -1, (0, 0, 0))], 9, "wood_crate", None


def model_emitter():
    mat = "emitter"
    m = combine(
        box(mat, R_METAL, (-6, -6, 0), (6, 6, 1.5)),
        cylinder(mat, R_BODY, 3.5, 12.5, 28, base=(0, 0, 1.5), cap_rect=R_CAP, fit=False),
        cylinder(mat, R_CAP, 1.6, 4.0, 18, base=(0, 0, 14), r_top=0.8, cap_rect=R_CAP),
        torus(mat, R_METAL, 3.6, 0.3, center=(0, 0, 8), seg=28, side=6),
    )
    phys = box("phys", R_METAL, (-6, -6, 0), (6, 6, 18))
    return m, phys, [("root", -1, (0, 0, 0))], 8, "metal", None


MODELS = {
    "gas_grenade": (model_grenade, textures_grenade),
    "gas_cylinder": (model_canister, textures_cylinder),
    "propane_tank": (model_propane, lambda: {"propane": with_normal("propane", tex_propane())}),
    "exhaust_fan": (model_fan, textures_fan),
    "gas_vent": (model_vent, textures_vent),
    "hose_nozzle": (model_nozzle, lambda: {"nozzle": tex_nozzle()}),
    # противогаз и запасной фильтр — модель ГП-7 (CC BY, assets/third_party), без неё — процедурные
    "gasmask": (lambda: model_gasmask_gp7() if gp7_available() else model_gasmask(),
                lambda: gp7_textures() if gp7_available() else {"gasmask": with_normal("gasmask", tex_gasmask())}),
    "gas_filter": (lambda: model_filter_gp7() if gp7_available() else model_filter(), lambda: {}),   # материалы противогаза
    "gas_analyzer": (model_analyzer, lambda: {"analyzer": with_normal("analyzer", tex_analyzer())}),
    "gas_emitter": (model_emitter, lambda: {"emitter": tex_emitter()}),
    "hazmat_suit": (model_hazmat, lambda: {"hazmat": with_normal("hazmat", tex_hazmat())}),
    "signal_flare": (model_flare, textures_flare),
    "antidote_atropine": (model_atropine, lambda: textures_antidote("atropine")),
    "antidote_eyewash": (model_eyewash, lambda: textures_antidote("eyewash")),
    "antidote_oxygen": (model_oxygen, lambda: textures_antidote("oxygen")),
    "antidote_decon": (model_decon, lambda: textures_antidote("decon")),
    "gas_sprayer": (model_sprayer, lambda: {"sprayer": with_normal("sprayer", tex_sprayer()),
                                            "sprayer_tank": with_normal("sprayer_tank", tex_sprayer_tank())}),
}


for _g in GAS_ORDER:
    MODELS[f"gas_cylinder_{_g}"] = (lambda g=_g: model_canister_gas(g), lambda: {})


def build_model(name):
    geom, texfn = MODELS[name]
    mesh, phys, bones, mass, surface, skins = geom()
    for tname, img in texfn().items():
        if isinstance(img, tuple):   # (цвет, параметры VMT)
            save_texture(tname, img[0], vmt_extra=img[1])
        else:
            save_texture(tname, img, envmap=tname != "gasmask")
    work = os.path.join(BUILD, name)
    os.makedirs(work, exist_ok=True)
    write_smd(os.path.join(work, "ref.smd"), mesh, bones)
    write_smd(os.path.join(work, "phys.smd"), phys, bones[:1])
    qc = os.path.join(work, f"{name}.qc")
    write_qc(qc, name, "ref.smd", "phys.smd", mass, surface, skins)
    compile_model(qc)
    src = os.path.join(GAME, "models", "aether")
    dst = os.path.join(ADDON, "models", "aether")
    os.makedirs(dst, exist_ok=True)
    for ext in (".dx80.vtx", ".sw.vtx"):   # GMod рисует только на DX9: эти варианты — лишний вес
        for d in (src, dst):
            if os.path.exists(os.path.join(d, name + ext)):
                os.remove(os.path.join(d, name + ext))
    for ext in (".mdl", ".vvd", ".dx90.vtx", ".phy"):
        p = os.path.join(src, name + ext)
        if os.path.exists(p):
            shutil.move(p, os.path.join(dst, name + ext))
    return mesh


# =============================================================================================
# Иконки: программный растеризатор (ортопроекция 3/4, ламберт + окружение + контровой свет)
# =============================================================================================
def raster_mesh(mesh, tex_lookup, yaw=35, pitch=22, size=512, ss=2, fill=0.78):
    """Программный растеризатор: модель без фона (RGBA, прозрачные пиксели вокруг). Для иконок и обложки."""
    N = size * ss
    tris = mesh.tris
    P = np.array([[v[0] for v in t[2]] for t in tris], float)          # (T,3,3)
    Nn = np.array([[v[1] for v in t[2]] for t in tris], float)
    UV = np.array([[v[2] for v in t[2]] for t in tris], float)
    mats = [t[0] for t in tris]
    # Камера на +X вида смотрит в −X: правая рука = +Y вида, верх = +Z. Наклон — вокруг Y вида
    # (верх модели уходит к камере), разворот — вокруг Z модели.
    R = rot_axis((0, 1, 0), math.radians(pitch)) @ rot_axis((0, 0, 1), math.radians(yaw))
    Pv = P @ R.T
    Nv = Nn @ R.T
    sx, sy, depth = Pv[..., 1], Pv[..., 2], Pv[..., 0]
    xmin, xmax, ymin, ymax = sx.min(), sx.max(), sy.min(), sy.max()
    scale = fill * N / max(xmax - xmin, ymax - ymin)
    cx, cy = (xmin + xmax) / 2, (ymin + ymax) / 2
    X = (sx - cx) * scale + N / 2
    Y = N / 2 - (sy - cy) * scale
    zbuf = np.full((N, N), -1e9)
    col = np.zeros((N, N, 3))
    alpha = np.zeros((N, N))
    light = np.array([0.5, -0.4, 0.75]); light /= np.linalg.norm(light)
    rim = np.array([-0.7, 0.5, 0.2]); rim /= np.linalg.norm(rim)
    texcache = {}
    for i in range(len(tris)):
        x0, x1, x2 = X[i]; y0, y1, y2 = Y[i]
        bx0, bx1 = int(max(0, math.floor(min(x0, x1, x2)))), int(min(N - 1, math.ceil(max(x0, x1, x2))))
        by0, by1 = int(max(0, math.floor(min(y0, y1, y2)))), int(min(N - 1, math.ceil(max(y0, y1, y2))))
        if bx1 < bx0 or by1 < by0:
            continue
        den = (y1 - y2) * (x0 - x2) + (x2 - x1) * (y0 - y2)
        if abs(den) < 1e-9:
            continue
        gx, gy = np.meshgrid(np.arange(bx0, bx1 + 1) + 0.5, np.arange(by0, by1 + 1) + 0.5)
        w0 = ((y1 - y2) * (gx - x2) + (x2 - x1) * (gy - y2)) / den
        w1 = ((y2 - y0) * (gx - x2) + (x0 - x2) * (gy - y2)) / den
        w2 = 1 - w0 - w1
        inside = (w0 >= 0) & (w1 >= 0) & (w2 >= 0)
        if not inside.any():
            continue
        z = w0 * depth[i, 0] + w1 * depth[i, 1] + w2 * depth[i, 2]
        sub = zbuf[by0:by1 + 1, bx0:bx1 + 1]
        vis = inside & (z > sub)
        if not vis.any():
            continue
        n = w0[..., None] * Nv[i, 0] + w1[..., None] * Nv[i, 1] + w2[..., None] * Nv[i, 2]
        n /= np.linalg.norm(n, axis=-1, keepdims=True) + 1e-9
        # вид: камера смотрит вдоль −x вида → нормаль к камере имеет x > 0
        lam = np.clip(n @ (R @ light), 0, 1)
        rimv = np.clip(n @ (R @ rim), 0, 1) ** 2
        u = w0 * UV[i, 0, 0] + w1 * UV[i, 1, 0] + w2 * UV[i, 2, 0]
        v = w0 * UV[i, 0, 1] + w1 * UV[i, 1, 1] + w2 * UV[i, 2, 1]
        tex = texcache.setdefault(mats[i], np.asarray(tex_lookup(mats[i]), float) / 255)
        th, tw = tex.shape[:2]
        tc = tex[np.clip((v * th).astype(int), 0, th - 1), np.clip((u * tw).astype(int), 0, tw - 1)]
        shade = 0.38 + 0.75 * lam[..., None] + 0.35 * rimv[..., None]
        c = np.clip(tc * shade, 0, 1)
        sub[vis] = z[vis]
        col[by0:by1 + 1, bx0:bx1 + 1][vis] = c[vis]
        alpha[by0:by1 + 1, bx0:bx1 + 1][vis] = 1
    return Image.fromarray((np.dstack([col, alpha[..., None]]) * 255).astype(np.uint8), "RGBA").resize((size, size), Image.LANCZOS)


def render_icon(mesh, tex_lookup, out_png, glow=(160, 160, 170), yaw=35, pitch=22, size=256, ss=2):
    obj = raster_mesh(mesh, tex_lookup, yaw, pitch, size, ss)
    # фон: тёмная плашка + цветное облако газа + мягкая тень
    bg = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(bg)
    d.rounded_rectangle([0, 0, size - 1, size - 1], 48, fill=(28, 32, 36, 255))
    puff = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    dp = ImageDraw.Draw(puff)
    rnd = random.Random(hash(out_png) & 0xffff)
    for _ in range(14):
        r = rnd.uniform(60, 140)
        x, y = rnd.uniform(size * 0.2, size * 0.8), rnd.uniform(size * 0.15, size * 0.65)
        dp.ellipse([x - r, y - r, x + r, y + r], fill=glow + (rnd.randint(30, 60),))
    puff = puff.filter(ImageFilter.GaussianBlur(28))
    shadow = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).ellipse([size * 0.22, size * 0.8, size * 0.78, size * 0.92], fill=(0, 0, 0, 140))
    shadow = shadow.filter(ImageFilter.GaussianBlur(14))
    out = Image.alpha_composite(Image.alpha_composite(Image.alpha_composite(bg, puff), shadow), obj)
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, size - 1, size - 1], 48, fill=255)
    out.putalpha(Image.fromarray(np.minimum(np.array(out.split()[3]), np.array(mask))))
    os.makedirs(os.path.dirname(out_png), exist_ok=True)
    out.save(out_png)


ICONS = {  # класс → (модель, материал-подмена для скина, свечение, yaw, pitch)
    "aether_grenade": ("gas_grenade", None, (190, 190, 200), 30, 18),
    "aether_canister": ("gas_cylinder", "cylinder_su_chlorine", (196, 206, 62), 0, 10),
    "aether_propane": ("propane_tank", None, (230, 120, 40), 30, 20),
    "aether_fan": ("exhaust_fan", "fan_su", (150, 170, 190), 20, 15),
    "aether_blower": ("exhaust_fan", "fan_blower_su", (230, 160, 70), 20, 15),
    "aether_vent": ("gas_vent", "vent_su_in", (90, 150, 230), 30, 10),
    "aether_gasmask": ("gasmask", None, (120, 170, 120), 35, 8),
    "weapon_aether_grenade": ("gas_grenade", "grenade_chlorine", (196, 206, 62), -30, 18),
    "weapon_aether_analyzer": ("gas_analyzer", None, (90, 255, 120), 30, 12),
    "weapon_aether_gasgun": ("gas_sprayer", None, (110, 210, 255), 70, 12),
    "aether_filter": ("gas_filter", None, (120, 170, 120), 30, 22),
    "aether_hazmat": ("hazmat_suit", None, (120, 140, 90), 30, 28),
    "weapon_aether_flare": ("signal_flare", "flare_signal_red", (214, 52, 44), 30, 20),
    "aether_atropine": ("antidote_atropine", None, (214, 180, 40), 30, 25),
    "aether_eyewash": ("antidote_eyewash", None, (90, 150, 230), 30, 20),
    "aether_oxygen": ("antidote_oxygen", None, (120, 180, 230), 30, 15),
    "aether_decon": ("antidote_decon", None, (150, 170, 110), 30, 40),
    "aether_cylinder_plain": ("gas_cylinder", "cylinder_plain", (150, 135, 110), 30, 12),
}
for _g in FLARE_ORDER:   # пресеты фаеров спавн-меню
    ICONS["aether_flare_" + _g] = ("signal_flare", "flare_" + _g, GAS_GLOW[_g], 30, 20)
    ICONS["weapon_aether_flare_" + _g.split("_")[1]] = ("signal_flare", "flare_" + _g, GAS_GLOW[_g], 30, 20)
for _g in GAS_ORDER:   # гранаты и баллоны-пресеты на каждый газ (скины)
    ICONS["weapon_aether_grenade_" + _g] = ("gas_grenade", "grenade_" + _g, GAS_GLOW[_g], -30, 18)
    ICONS["aether_cylinder_" + _g] = ("gas_cylinder", "cylinder_su_" + _g, GAS_GLOW[_g], 0, 10)


def build_icons(meshes):
    texdir = os.path.join(BUILD, "tex")
    for cls, (model, swap, glow, yaw, pitch) in ICONS.items():
        mesh = meshes[model]
        def lookup(mat, swap=swap):
            name = swap if (swap and mat.split("_")[0] == swap.split("_")[0]) else mat
            return Image.open(os.path.join(texdir, name + ".png")).convert("RGB")
        render_icon(mesh, lookup, os.path.join(ADDON, "materials", "entities", cls + ".png"), glow, yaw, pitch)


def build_killicons():
    """Белые силуэты 128×64 для ленты убийств: облако с черепом (газ) и пламя (огонь)."""
    out = os.path.join(ADDON, "materials", "aether")
    for name, draw_fn in (("killicon_gas", "gas"), ("killicon_fire", "fire")):
        S = 4
        img = Image.new("RGBA", (128 * S, 64 * S), (0, 0, 0, 0))
        d = ImageDraw.Draw(img)
        if draw_fn == "gas":
            for x, y, r in ((40, 36, 18), (62, 28, 22), (86, 36, 18), (62, 44, 16)):
                d.ellipse([(x - r) * S, (y - r) * S, (x + r) * S, (y + r) * S], fill=(255, 255, 255, 255))
            d.ellipse([54 * S, 22 * S, 70 * S, 38 * S], fill=(0, 0, 0, 0))
            d.rectangle([57 * S, 36 * S, 67 * S, 42 * S], fill=(0, 0, 0, 0))
            d.ellipse([57 * S, 27 * S, 61 * S, 31 * S], fill=(255, 255, 255, 255))
            d.ellipse([63 * S, 27 * S, 67 * S, 31 * S], fill=(255, 255, 255, 255))
        else:
            d.polygon([(64 * S, 4 * S), (80 * S, 30 * S), (76 * S, 60 * S), (52 * S, 60 * S), (46 * S, 34 * S), (56 * S, 40 * S)], fill=(255, 255, 255, 255))
            d.polygon([(64 * S, 30 * S), (70 * S, 46 * S), (66 * S, 58 * S), (60 * S, 58 * S), (58 * S, 46 * S)], fill=(0, 0, 0, 0))
        img = img.resize((128, 64), Image.LANCZOS)
        os.makedirs(out, exist_ok=True)
        write_vtf_rgba(os.path.join(out, name + ".vtf"), img)
        with open(os.path.join(out, name + ".vmt"), "w", newline="\n") as f:
            f.write('"UnlitGeneric"\n{\n\t"$basetexture" "aether/' + name + '"\n\t"$vertexcolor" "1"\n\t"$vertexalpha" "1"\n\t"$translucent" "1"\n}\n')


def write_vtf_dxt(name, img):
    """RGBA → materials/aether/<name>.vtf через vtex (DXT5 со сжатием альфы, mip-цепочка)."""
    src = os.path.join(GAME, "materialsrc", "aether")
    os.makedirs(src, exist_ok=True)
    tga = os.path.join(src, name + ".tga")
    img.convert("RGBA").save(tga)
    r = subprocess.run([os.path.join(GMOD, "bin", "vtex.exe"), "-game", GAME, "-nopause", "-quiet", tga],
                       capture_output=True, text=True, timeout=300)
    if "SUCCESS" not in r.stdout:
        raise RuntimeError(f"vtex failed for {name}: {r.stdout[-1500:]}")
    dst = os.path.join(ADDON, "materials", "aether")
    os.makedirs(dst, exist_ok=True)
    shutil.move(os.path.join(GAME, "materials", "aether", name + ".vtf"), os.path.join(dst, name + ".vtf"))
    shutil.rmtree(src, ignore_errors=True)


def build_mask_overlay():
    """Оверлей маски 1024×512: тёмная резиновая рамка, две панорамные линзы с мягким краем, лёгкая
    тонировка и царапины стекла. Плюс отдельная текстура запотевания (нижняя часть линз)."""
    W, H = 1024, 512
    out = os.path.join(ADDON, "materials", "aether")
    lens = Image.new("L", (W, H), 0)
    d = ImageDraw.Draw(lens)
    o = rounded_outline(**LENS, seg=64)
    for cx, side in ((W * 0.29, -1), (W * 0.71, 1)):   # u — наружу: у левой линзы влево, у правой вправо
        k = 205 / LENS["w"]
        d.polygon([(cx + side * u * k, 250 - v * k * 0.93) for u, v in o], fill=255)
    lens = lens.filter(ImageFilter.GaussianBlur(22))
    frame_a = np.clip(255 - np.array(lens, float) * 1.15, 0, 255)
    rubber = np.array(noise_img((W, H), (14, 15, 14), 5, 7, 1.0)).astype(float)
    glass = np.zeros((H, W, 3)) + np.array([40, 52, 48], float)
    a_glass = np.array(lens, float) / 255 * 26
    rgb = rubber * (frame_a[..., None] / 255) + glass * (1 - frame_a[..., None] / 255)
    a = np.maximum(frame_a, a_glass)
    img = Image.fromarray(np.dstack([rgb, a]).astype(np.uint8), "RGBA")
    dg = ImageDraw.Draw(img)
    rnd = random.Random(5)
    for _ in range(40):   # царапины и пылинки на стекле
        x, y = rnd.uniform(120, W - 120), rnd.uniform(90, H - 90)
        L, ang = rnd.uniform(6, 40), rnd.uniform(0, math.pi)
        dg.line([(x, y), (x + L * math.cos(ang), y + L * math.sin(ang))], fill=(220, 225, 220, rnd.randint(18, 40)), width=1)
    write_vtf_dxt("mask_overlay", img)

    fog = Image.new("L", (W, H), 0)
    df = ImageDraw.Draw(fog)
    for cx in (W * 0.29, W * 0.71):
        df.ellipse([cx - 200, 300, cx + 200, 470], fill=200)
    fog = Image.composite(fog, Image.new("L", (W, H), 0), lens).filter(ImageFilter.GaussianBlur(30))
    fog_img = Image.merge("RGBA", (Image.new("L", (W, H), 235),) * 3 + (fog,))
    write_vtf_dxt("mask_breath", fog_img)
    for name in ("mask_overlay", "mask_breath"):
        with open(os.path.join(out, name + ".vmt"), "w", newline="\n") as f:
            f.write('"UnlitGeneric"\n{\n\t"$basetexture" "aether/' + name + '"\n\t"$vertexcolor" "1"\n\t"$vertexalpha" "1"\n\t"$translucent" "1"\n}\n')


def build_flare_glow():
    """Свечение горящего фаера: радиальный белый спрайт 128×128 (цвет — вершинный), аддитивный."""
    N = 128
    y, x = np.mgrid[0:N, 0:N].astype(float)
    r = np.sqrt((x - N / 2 + 0.5) ** 2 + (y - N / 2 + 0.5) ** 2) / (N / 2)
    a = np.clip(1 - r, 0, 1) ** 2.2 + np.clip(1 - r * 4, 0, 1) * 0.8      # мягкий ореол + яркое ядро
    v = np.uint8(np.clip(a, 0, 1) * 255)
    img = Image.merge("RGBA", (Image.fromarray(v),) * 3 + (Image.fromarray(v),))
    out = os.path.join(ADDON, "materials", "aether")
    os.makedirs(out, exist_ok=True)
    write_vtf_rgba(os.path.join(out, "flare_glow.vtf"), img)
    with open(os.path.join(out, "flare_glow.vmt"), "w", newline="\n") as f:
        f.write('"UnlitGeneric"\n{\n\t"$basetexture" "aether/flare_glow"\n\t"$additive" "1"\n'
                '\t"$vertexcolor" "1"\n\t"$vertexalpha" "1"\n\t"$nocull" "1"\n}\n')


def write_vtf_rgba(path, img):
    """Несжатый BGRA8888 VTF 7.2 с mip-цепочкой (размеры — степени двойки)."""
    import struct
    w, h = img.size
    mips = [img]
    while mips[-1].size != (1, 1):
        mw, mh = max(1, mips[-1].size[0] // 2), max(1, mips[-1].size[1] // 2)
        mips.append(mips[-1].resize((mw, mh), Image.LANCZOS))
    header = struct.pack("<4s2IIHHIHH4x3f4xfIBiBBH", b"VTF\0", 7, 2, 80, w, h, 0x2000 | 0x4 | 0x8, 1, 0,
                         1.0, 1.0, 1.0, 1.0, 12, len(mips), -1, 0, 0, 1)
    header += b"\0" * (80 - len(header))
    data = b""
    for m in reversed(mips):
        a = np.array(m.convert("RGBA"))
        data += a[..., [2, 1, 0, 3]].tobytes()
    with open(path, "wb") as f:
        f.write(header + data)


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", default="")
    args = ap.parse_args()
    names = [n for n in MODELS if not args.only or n in args.only.split(",")]
    meshes = {}
    for n in names:
        meshes[n] = build_model(n)
        print("model ok:", n, len(meshes[n].tris), "tris")
    if not args.only:
        build_icons(meshes)
        build_killicons()
        build_mask_overlay()
        build_flare_glow()
        print("icons ok")
    shutil.rmtree(os.path.join(GAME, "materialsrc", "models", "aether"), ignore_errors=True)
