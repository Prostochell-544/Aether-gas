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
    paste_region(img, metal((256, 128), (176, 150, 80), 8), (0.5, 0.75, 1, 1))   # латунь
    return img


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
    paste_region(img, metal((256, 128), (118, 98, 58), 124), (0.5, 0.75, 1, 1))   # потемневшая латунь
    return img


def tex_propane():
    S = 512
    img = Image.new("RGB", (S, S))
    body = noise_img((S, 320), (178, 32, 28), 8, 31)
    d = ImageDraw.Draw(body)
    for k in range(2):
        cx = S * (0.25 + 0.5 * k)
        text_centered(d, (cx - 120, 70, cx + 120, 150), "PROPANE", font("impact.ttf", 64), (250, 248, 240))
        text_centered(d, (cx - 120, 155, cx + 120, 185), "FLAMMABLE GAS", font("consolab.ttf", 20), (250, 240, 220))
        nfpa_diamond(body, int(cx) - 92, 230, 36, 2, 4, 0, "")
        ghs_pictogram(body, int(cx) + 10, 262, 28, "flame")
        ghs_pictogram(body, int(cx) + 74, 262, 28, "cyl")
        un_plate(body, int(cx) + 150, 262, 56, "1978")
    wear(body, 9, 160, (210, 120, 110))
    paste_region(img, face_front(body), R_BODY)
    paste_region(img, noise_img((256, 192), (170, 30, 26), 8, 33), R_METAL)
    paste_region(img, metal((256, 192), (176, 150, 80), 34), R_CAP)
    return img


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
    text_centered(d, (0, 4, w, h - 4), text, font("impact.ttf", int(h * 0.72)), fg)
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


def tex_gasmask():
    """ГП-7: серо-чёрная матовая резина, тонированные линзы, оливковая фильтрующая коробка с маркировкой,
    воронёный металл обойм и клапанной коробки, тканевые ремни оголовья."""
    S = 512
    img = Image.new("RGB", (S, S))
    rubber = noise_img((S, 256), (58, 60, 60), 3, 51, 2.0)
    wear(rubber, 51, 14, (68, 70, 70))
    paste_region(img, rubber, M_RUBBER)
    glass = Image.new("RGB", (256, 256), (26, 38, 44))
    d = ImageDraw.Draw(glass)
    d.ellipse([46, 36, 150, 120], fill=(110, 140, 150))       # блик
    d.ellipse([150, 160, 200, 200], fill=(60, 80, 90))
    paste_region(img, glass.filter(ImageFilter.GaussianBlur(18)), M_GLASS)
    filt = noise_img((512, 154), (78, 86, 56), 6, 52)          # по окружности фильтра — u, по высоте — v
    d = ImageDraw.Draw(filt)
    for y in (6, 138):
        d.rectangle([0, y, 512, y + 10], fill=(52, 56, 38))
    for k in range(2):
        cx = 128 + 256 * k
        text_centered(d, (cx - 110, 30, cx + 110, 80), "GP-7K", font("impact.ttf", 40), (226, 220, 176))
        text_centered(d, (cx - 110, 86, cx + 110, 112), "FILTER  ABEK2-P3", font("consolab.ttf", 17), (210, 205, 160))
    paste_region(img, filt, M_FILTER)
    paste_region(img, metal((128, 102), (70, 72, 76), 53), M_METAL)
    strap = noise_img((128, 102), (40, 42, 40), 6, 54, 0.6)
    ds = ImageDraw.Draw(strap)
    for x in range(0, 128, 5):
        ds.line([(x, 0), (x, 102)], fill=(34, 36, 34))
    paste_region(img, strap, M_STRAP)
    return img


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


def tex_analyzer():
    S = 512
    img = Image.new("RGB", (S, S))
    casing = noise_img((S, 256), (222, 176, 34), 6, 61)
    stripes(casing, (0, 0, S, 26))
    d = ImageDraw.Draw(casing)
    text_centered(d, (8, 112, 150, 168), "GA-1", font("impact.ttf", 44), (30, 30, 30))
    paste_region(img, casing, (0, 0, 1, 0.5))
    screen = noise_img((256, 256), (8, 20, 12), 3, 63, 1.5)   # пустой экран: данные рисует SWEP (3D2D)
    paste_region(img, screen, (0, 0.5, 0.5, 1))
    pad = noise_img((256, 256), (34, 34, 36), 5, 62)
    d = ImageDraw.Draw(pad)
    for r in range(3):
        for c in range(3):
            d.rounded_rectangle([30 + c * 70, 30 + r * 70, 80 + c * 70, 80 + r * 70], 8, fill=(70, 70, 74))
    paste_region(img, pad, (0.5, 0.5, 1, 1))
    return img


S_GAUGE, S_GRIP = (0.5, 0.5, 0.75, 0.75), (0.75, 0.5, 1, 0.75)


def tex_sprayer():
    """Газомёт: тёмный корпус с оранжевыми вставками, воронёный металл, манометр, резина рукояти, табличка."""
    S = 512
    img = Image.new("RGB", (S, S))
    body = metal((S, 256), (58, 60, 64), 101)
    d = ImageDraw.Draw(body)
    d.rectangle([0, 200, S, 222], fill=(214, 120, 36))
    wear(body, 101, 70)
    paste_region(img, body, R_PAINT)
    paste_region(img, metal((256, 256), (36, 38, 42), 102), R_DARK)
    g = Image.new("RGB", (128, 128), (235, 232, 220))
    dg = ImageDraw.Draw(g)
    dg.ellipse([4, 4, 124, 124], outline=(30, 30, 30), width=6)
    for k in range(9):
        a = math.radians(225 - k * 270 / 8)
        dg.line([(64 + 44 * math.cos(a), 64 - 44 * math.sin(a)), (64 + 54 * math.cos(a), 64 - 54 * math.sin(a))],
                fill=(30, 30, 30), width=3)
    dg.arc([14, 14, 114, 114], -45, 0, fill=(200, 40, 30), width=8)
    dg.line([(64, 64), (64 + 40 * math.cos(math.radians(150)), 64 - 40 * math.sin(math.radians(150)))], fill=(200, 30, 20), width=4)
    dg.ellipse([58, 58, 70, 70], fill=(30, 30, 30))
    paste_region(img, g, S_GAUGE)
    grip = noise_img((128, 128), (34, 34, 34), 5, 103)
    dr = ImageDraw.Draw(grip)
    for y in range(0, 128, 8):
        dr.line([(0, y), (128, y)], fill=(22, 22, 22), width=2)
    paste_region(img, grip, S_GRIP)
    paste_region(img, label_plate("AETHER GS-1", 5.0, (214, 120, 36), (20, 20, 20)), R_PLATE)
    return img


def tex_sprayer_tank():
    """Бак: светлое «стекло» — в игре тонируется в цвет газа ($color2), риски уровня и блик."""
    S = 256
    img = Image.new("RGB", (S, S), (226, 230, 234))
    d = ImageDraw.Draw(img)
    for x in range(16, S, 32):
        d.line([(x, 150), (x, 200)], fill=(150, 154, 160), width=3)
    d.rectangle([0, 110, S, 118], fill=(250, 252, 255))
    return img.filter(ImageFilter.GaussianBlur(1.2))


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


def save_texture(name, img, envmap=True):
    src = os.path.join(GAME, "materialsrc", "models", "aether")
    os.makedirs(src, exist_ok=True)
    tga = os.path.join(src, name + ".tga")
    img.convert("RGB").save(tga)
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
    if envmap:
        vmt += ['\t"$envmap" "env_cubemap"', '\t"$envmaptint" "[.06 .06 .06]"']
    vmt += ["}"]
    with open(os.path.join(dst, name + ".vmt"), "w", newline="\n") as f:
        f.write("\n".join(vmt) + "\n")


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
    return m, phys, [("root", -1, (0, 0, 0))], 0.6, "metal", [f"grenade_{g}" for g in GAS_ORDER]


def model_canister():
    mat = "cylinder_smoke"   # = первая строка $texturegroup, иначе скины не подменяют материал
    rb, rs, rm = (0, 0, 1, 0.75), (0, 0.75, 0.5, 1), (0.5, 0.75, 1, 1)
    m = combine(
        cylinder(mat, rb, 4.5, 34, 32, cap_rect=rs, fit=False),
        ellipsoid(mat, rs, (4.5, 4.5, 4.0), center=(0, 0, 34), part="top", seg=32, rings=8),
        cylinder(mat, rm, 1.3, 3.0, 20, base=(0, 0, 37.6), cap_rect=rm),
        box(mat, rm, (-1.0, -1.0, 40.5), (1.0, 1.0, 42.5)),
        cylinder(mat, rm, 0.45, 1.6, 12, base=(1.0, 0, 41.5), axis=(1, 0, 0), cap_rect=rm),
        cylinder(mat, rm, 0.25, 1.1, 10, base=(0, 0, 42.5), cap_rect=rm),
        torus(mat, rm, 1.5, 0.22, center=(0, 0, 43.5), seg=24, side=8),
        box(mat, rm, (-1.5, -0.12, 43.38), (1.5, 0.12, 43.62)),
        box(mat, rm, (-0.12, -1.5, 43.38), (0.12, 1.5, 43.62)),
    )
    phys = cylinder("phys", rb, 4.5, 43.8, 10)
    return m, phys, [("root", -1, (0, 0, 0))], 40, "metal", [f"cylinder_{g}" for g in GAS_ORDER] + ["cylinder_plain"]


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
    return m, phys, bones, 30, "metal", ["fan", "fan_blower"]


def model_gasmask():
    """Противогаз в духе ГП-7. Оси: X вперёд, Y влево, Z вверх; центр линз — на высоте 0.
    Лицевая часть — оболочка с охватом щёк до ушей (не «тарелка»), подбородочная чашка выдвинута вперёд,
    кант по краю. Две круглые линзы в обоймах, клапанная коробка с переговорной мембраной спереди внизу,
    фильтр на левой щеке, «паук» из 5 плоских ремней по форме затылка."""
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
        """Точка и внешняя нормаль оболочки (конечные разности)."""
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
    # кант по всему краю оболочки
    edge = [face(TH0, -PH + 2 * PH * i / 30) for i in range(31)] + [face(TH0 + (TH1 - TH0) * i / 16, PH) for i in range(1, 17)]         + [face(TH1, PH - 2 * PH * i / 30) for i in range(1, 31)] + [face(TH1 - (TH1 - TH0) * i / 16, -PH) for i in range(1, 17)]
    parts.append(tube(mat, M_RUBBER, edge, 0.2, 6))

    # линзы: центр на оболочке, ось — между нормалью и «вперёд»
    for sy in (-1, 1):
        ph = 0.4 * sy
        th = math.asin((0.0 - C[2]) / RZ)          # высота центра линзы = 0
        p, n = surf(th, ph)
        ax = n * 0.55 + np.array([1.0, 0, 0]) * 0.45
        ax /= np.linalg.norm(ax)
        parts.append(cylinder(mat, M_METAL, 1.28, 0.35, 28, base=tuple(p - ax * 0.1), axis=tuple(ax), cap_rect=M_GLASS))
        parts.append(cylinder(mat, M_GLASS, 1.08, 0.42, 28, base=tuple(p - ax * 0.05), axis=tuple(ax), cap_rect=M_GLASS))
        parts.append(torus(mat, M_METAL, 1.2, 0.17, center=tuple(p + ax * 0.38), axis=tuple(ax), seg=28, side=6))

    # клапанная коробка (переговорная мембрана) и клапан выдоха под ней
    p, n = surf(-0.62, 0.0)
    ax = n * 0.6 + np.array([1.0, 0, -0.35]) * 0.4
    ax /= np.linalg.norm(ax)
    parts.append(cylinder(mat, M_METAL, 1.05, 0.95, 24, base=tuple(p - ax * 0.3), axis=tuple(ax), cap_rect=M_METAL))
    parts.append(torus(mat, M_METAL, 1.05, 0.14, center=tuple(p + ax * 0.65), axis=tuple(ax), seg=24, side=5))
    parts.append(cylinder(mat, M_RUBBER, 0.7, 0.3, 20, base=tuple(p + ax * 0.65), axis=tuple(ax), cap_rect=M_STRAP))
    q, nq = surf(-0.98, 0.0)
    parts.append(cylinder(mat, M_METAL, 0.62, 0.7, 18, base=tuple(q - nq * 0.2), axis=tuple(nq), cap_rect=M_STRAP))

    # фильтр на левой щеке (+Y): горловина + коробка ∅4, ось вперёд-вниз-влево
    p, n = surf(-0.55, 0.92)
    fa = n * 0.5 + np.array([0.75, 0.25, -0.45]) * 0.5
    fa /= np.linalg.norm(fa)
    parts.append(cylinder(mat, M_METAL, 0.85, 0.75, 18, base=tuple(p - fa * 0.2), axis=tuple(fa), cap_rect=M_METAL))
    base = p + fa * 0.5
    parts.append(cylinder(mat, M_FILTER, 2.0, 2.7, 30, base=tuple(base), axis=tuple(fa), cap_rect=M_METAL, fit=False))
    parts.append(torus(mat, M_METAL, 2.0, 0.12, center=tuple(base + fa * 2.7), axis=tuple(fa), seg=30, side=5))

    # оголовье «паук»: ремни от края маски по форме головы к затылочной пластине
    H = np.array([-3.0, 0.0, 0.3])                 # центр головы
    HR = np.array([4.4, 3.65, 4.7])

    def on_head(d, off=0.18):
        d = d / np.linalg.norm(d)
        k = 1 / math.sqrt((d[0] / HR[0]) ** 2 + (d[1] / HR[1]) ** 2 + (d[2] / HR[2]) ** 2)
        p = H + d * k
        n = (p - H) / HR ** 2
        n /= np.linalg.norm(n)
        return p + n * off, n

    back = np.array([-1.0, 0.0, 0.35])               # затылок
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
        parts.append(box(mat, M_METAL, tuple(a - 0.3), tuple(a + 0.3)))   # пряжка у края маски
    p, n = on_head(back, 0.22)
    parts.append(cylinder(mat, M_STRAP, 1.3, 0.12, 20, base=tuple(p), axis=tuple(n), cap_rect=M_STRAP))   # пластина
    m = combine(*parts)
    phys = box("phys", M_RUBBER, (-7.2, -3.8, -5.6), (2.8, 3.8, 4.4))
    return m, phys, [("root", -1, (0, 0, 0))], 1, "rubber", None


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
    return m, phys, [("root", -1, (0, 0, 0))], 6, "metal", ["vent_in", "vent_out"]


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


def model_analyzer():
    mat = "analyzer"
    rc, rs, rp = (0, 0, 1, 0.5), (0, 0.5, 0.5, 1), (0.5, 0.5, 1, 1)
    m = combine(
        box(mat, rc, (-1.0, -2.0, 0.8), (1.0, 2.0, 7.0)),
        box(mat, rp, (-1.05, -2.05, 0), (1.05, 2.05, 0.8)),
        box(mat, rs, (1.0, -1.6, 3.7), (1.12, 1.6, 6.4)),
        box(mat, rp, (1.0, -1.4, 1.2), (1.08, 1.4, 3.3)),
        cylinder(mat, rp, 0.28, 3.4, 10, base=(0, 1.3, 7.0)),
        cylinder(mat, rc, 0.45, 0.6, 12, base=(0, 1.3, 10.4)),
    )
    phys = box("phys", rc, (-1.05, -2.05, 0), (1.12, 2.05, 7.0))
    return m, phys, [("root", -1, (0, 0, 0))], 1, "plastic", None


def model_sprayer():
    """Газомёт (+X — сопло): ствольная коробка, наклонная рукоять, скоба и спуск, бак сверху (свой
    материал sprayer_tank — тонируется в цвет газа), хомуты, вентиль, манометр, шланг к соплу, раструб."""
    mat, tank = "sprayer", "sprayer_tank"
    full = (0, 0, 1, 1)
    parts = [
        box(mat, R_PAINT, (-3.5, -0.75, -0.6), (5.5, 0.75, 1.4)),
        box(mat, S_GRIP, (-1.0, -0.65, -4.6), (1.0, 0.65, 0.0), M=rot_axis((0, 1, 0), math.radians(15)), t=(-2.0, 0, -0.5)),
        torus_arc(mat, R_DARK, 0.95, 0.12, math.pi, 2 * math.pi, center=(0.3, 0, -0.65),
                  M2=rot_axis((1, 0, 0), math.pi / 2), seg=12, side=5),
        box(mat, R_DARK, (-0.05, -0.15, -1.35), (0.3, 0.15, -0.6)),
        cylinder(tank, full, 1.5, 6.0, 26, base=(-3.2, 0, 3.0), axis=(1, 0, 0)),
        box(mat, R_DARK, (-2.6, -0.45, 1.4), (-1.6, 0.45, 1.75)),
        box(mat, R_DARK, (1.2, -0.45, 1.4), (2.2, 0.45, 1.75)),
        cylinder(mat, R_DARK, 0.3, 0.9, 12, base=(1.6, 0, 4.4)),
        torus(mat, R_DARK, 0.45, 0.08, center=(1.6, 0, 5.35), seg=14, side=5),
        cylinder(mat, R_DARK, 0.6, 0.35, 18, base=(3.7, -0.75, 0.45), axis=(0, -1, 0), cap_rect=S_GAUGE),
        tube(mat, R_DARK, [(2.8, 0, 1.7), (3.8, 0, 2.0), (4.6, 0, 1.5), (5.2, 0, 0.6)], 0.22, 8),
        cylinder(mat, R_DARK, 0.55, 5.6, 18, base=(5.5, 0, 0.4), axis=(1, 0, 0)),
        cylinder(mat, R_DARK, 0.55, 1.6, 18, base=(11.0, 0, 0.4), axis=(1, 0, 0), r_top=0.9),
        torus(mat, R_PAINT, 0.62, 0.1, center=(8.0, 0, 0.4), axis=(1, 0, 0), seg=16, side=5),
        box(mat, R_PLATE, (-3.0, 0.75, 0.05), (2.0, 0.8, 1.05), fit=False),
        box(mat, R_PLATE, (-3.0, -0.8, 0.05), (2.0, -0.75, 1.05), fit=False),
    ]
    for x in (-2.1, 1.7):   # хомуты бака
        parts.append(torus(mat, R_DARK, 1.55, 0.13, center=(x, 0, 3.0), axis=(1, 0, 0), seg=24, side=5))
    for x in (-3.2, 2.8):   # торцевые кольца бака
        parts.append(torus(mat, R_DARK, 1.45, 0.16, center=(x, 0, 3.0), axis=(1, 0, 0), seg=24, side=5))
    m = combine(*parts)
    phys = box("phys", R_PAINT, (-3.5, -0.9, -5.0), (12.6, 0.9, 4.6))
    return m, phys, [("root", -1, (0, 0, 0))], 2, "metal", None


def model_filter():
    """Фильтрующая коробка ГП-7 отдельно (запасной фильтр): материал противогаза, ось Z, горловина сверху."""
    mat = "gasmask"
    m = combine(
        cylinder(mat, M_FILTER, 2.0, 2.7, 30, cap_rect=M_METAL, fit=False),
        cylinder(mat, M_METAL, 0.85, 0.75, 18, base=(0, 0, 2.7), cap_rect=M_METAL),
        torus(mat, M_METAL, 2.0, 0.12, center=(0, 0, 2.7), seg=30, side=5),
        torus(mat, M_METAL, 2.0, 0.12, center=(0, 0, 0.0), seg=30, side=5),
        torus(mat, M_METAL, 0.9, 0.1, center=(0, 0, 3.3), seg=18, side=5),
    )
    phys = cylinder("phys", M_FILTER, 2.0, 3.45, 10)
    return m, phys, [("root", -1, (0, 0, 0))], 1, "plastic", None


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
    "gas_grenade": (model_grenade, lambda: {f"grenade_{g}": tex_grenade(g) for g in GAS_ORDER}),
    "gas_cylinder": (model_canister, lambda: {**{f"cylinder_{g}": tex_cylinder(g) for g in GAS_ORDER},
                                              "cylinder_plain": tex_cylinder_plain()}),
    "propane_tank": (model_propane, lambda: {"propane": tex_propane()}),
    "exhaust_fan": (model_fan, lambda: {"fan": tex_fan(), "fan_blower": tex_fan_blower()}),
    "gas_vent": (model_vent, lambda: {"vent_in": tex_vent(0), "vent_out": tex_vent(1)}),
    "hose_nozzle": (model_nozzle, lambda: {"nozzle": tex_nozzle()}),
    "gasmask": (model_gasmask, lambda: {"gasmask": tex_gasmask()}),
    "gas_filter": (model_filter, lambda: {}),   # материал противогаза (собирается после gasmask)
    "gas_analyzer": (model_analyzer, lambda: {"analyzer": tex_analyzer()}),
    "gas_emitter": (model_emitter, lambda: {"emitter": tex_emitter()}),
    "gas_sprayer": (model_sprayer, lambda: {"sprayer": tex_sprayer(), "sprayer_tank": tex_sprayer_tank()}),
}


def build_model(name):
    geom, texfn = MODELS[name]
    mesh, phys, bones, mass, surface, skins = geom()
    for tname, img in texfn().items():
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
    for ext in (".mdl", ".vvd", ".dx90.vtx", ".dx80.vtx", ".sw.vtx", ".phy"):
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


def render_icon(mesh, tex_lookup, out_png, glow=(160, 160, 170), yaw=35, pitch=22, size=512, ss=2):
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
    "aether_canister": ("gas_cylinder", None, (196, 206, 62), 30, 12),
    "aether_propane": ("propane_tank", None, (230, 120, 40), 30, 20),
    "aether_fan": ("exhaust_fan", None, (150, 170, 190), 20, 15),
    "aether_blower": ("exhaust_fan", "fan_blower", (230, 160, 70), 20, 15),
    "aether_vent": ("gas_vent", None, (90, 150, 230), 30, 10),
    "aether_gasmask": ("gasmask", None, (120, 170, 120), 35, 8),
    "weapon_aether_grenade": ("gas_grenade", "grenade_chlorine", (196, 206, 62), -30, 18),
    "weapon_aether_analyzer": ("gas_analyzer", None, (90, 255, 120), 30, 12),
    "weapon_aether_gasgun": ("gas_sprayer", None, (110, 210, 255), 70, 12),
    "aether_filter": ("gas_filter", None, (120, 170, 120), 30, 22),
    "aether_cylinder_plain": ("gas_cylinder", "cylinder_plain", (150, 135, 110), 30, 12),
}
for _g in GAS_ORDER:   # гранаты и баллоны-пресеты на каждый газ (скины)
    ICONS["weapon_aether_grenade_" + _g] = ("gas_grenade", "grenade_" + _g, GAS_GLOW[_g], -30, 18)
    ICONS["aether_cylinder_" + _g] = ("gas_cylinder", "cylinder_" + _g, GAS_GLOW[_g], 30, 12)


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


def build_mask_overlay():
    """Оверлей маски 1024×512: тёмная резиновая рамка, две панорамные линзы с мягким краем, лёгкая
    тонировка и царапины стекла. Плюс отдельная текстура запотевания (нижняя часть линз)."""
    W, H = 1024, 512
    out = os.path.join(ADDON, "materials", "aether")
    lens = Image.new("L", (W, H), 0)
    d = ImageDraw.Draw(lens)
    for cx in (W * 0.29, W * 0.71):
        d.ellipse([cx - 230, 70, cx + 230, 430], fill=255)
    d.polygon([(W * 0.5 - 40, 330), (W * 0.5 + 40, 330), (W * 0.5, 230)], fill=0)   # переносица
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
    write_vtf_rgba(os.path.join(out, "mask_overlay.vtf"), img)

    fog = Image.new("L", (W, H), 0)
    df = ImageDraw.Draw(fog)
    for cx in (W * 0.29, W * 0.71):
        df.ellipse([cx - 210, 300, cx + 210, 470], fill=200)
    fog = Image.composite(fog, Image.new("L", (W, H), 0), lens).filter(ImageFilter.GaussianBlur(30))
    fog_img = Image.merge("RGBA", (Image.new("L", (W, H), 235),) * 3 + (fog,))
    write_vtf_rgba(os.path.join(out, "mask_breath.vtf"), fog_img)
    for name in ("mask_overlay", "mask_breath"):
        with open(os.path.join(out, name + ".vmt"), "w", newline="\n") as f:
            f.write('"UnlitGeneric"\n{\n\t"$basetexture" "aether/' + name + '"\n\t"$vertexcolor" "1"\n\t"$vertexalpha" "1"\n\t"$translucent" "1"\n}\n')


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
        print("icons ok")
    shutil.rmtree(os.path.join(GAME, "materialsrc", "models", "aether"), ignore_errors=True)
