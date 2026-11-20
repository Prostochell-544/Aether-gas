"""Выгрузка моделей аддона в OBJ для Blender (витрина пропов, обложки Workshop).

    python -I tools/export_props.py        # → build/blender/<модель>.obj + props.json

Геометрия берётся прямо из генератора (make_models.MODELS, без studiomdl), текстуры — цветные PNG из
build/models/tex (их пишет make_models.py при сборке). Оси как в make_models: +Z вверх, +X — «вперёд»
(лицевая сторона надписей), единицы — юниты Source; масштаб и сцену задаёт tools/blender_scene.py.
props.json: материалы каждой модели и её скины (список вариантов первой строки $texturegroup).
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import make_models as M  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "build", "blender")
TEX = os.path.abspath(os.path.join(M.BUILD, "tex"))


def write_obj(path, mesh):
    by_mat = {}
    for mat, _bone, vs in mesh.tris:
        by_mat.setdefault(mat, []).append(vs)
    lines, vi = [], 1
    for mat, tris in by_mat.items():
        lines.append(f"o {mat}")
        lines.append(f"usemtl {mat}")
        for vs in tris:
            for p, n, (u, v) in vs:
                lines.append(f"v {p[0]:.4f} {p[1]:.4f} {p[2]:.4f}")
                lines.append(f"vt {u:.5f} {1 - v:.5f}")
                lines.append(f"vn {n[0]:.4f} {n[1]:.4f} {n[2]:.4f}")
            lines.append(f"f {vi}/{vi}/{vi} {vi + 1}/{vi + 1}/{vi + 1} {vi + 2}/{vi + 2}/{vi + 2}")
            vi += 3
    with open(path, "w", newline="\n") as f:
        f.write("\n".join(lines) + "\n")
    return list(by_mat)


def main():
    os.makedirs(OUT, exist_ok=True)
    meta = {"tex": TEX, "models": {}}
    for name, (geom, _tex) in M.MODELS.items():
        mesh, _phys, _bones, _mass, _surface, skins = geom()
        mats = write_obj(os.path.join(OUT, name + ".obj"), mesh)
        meta["models"][name] = {"mats": mats, "skins": skins or []}
        print("obj:", name, len(mesh.tris), flush=True)
    with open(os.path.join(OUT, "props.json"), "w", encoding="utf-8") as f:
        json.dump(meta, f, ensure_ascii=False, indent=1)
    print("ok:", OUT)


if __name__ == "__main__":
    main()
