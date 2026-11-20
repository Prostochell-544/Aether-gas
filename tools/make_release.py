"""Сборка релиза Aether.

    python -I tools/make_release.py           # release/repo (дерево для GitHub) + release/aether_gas.gma
    python -I tools/make_release.py --no-gma  # только дерево репозитория

Корень репозитория = корень аддона (lua/, materials/, models/, addon.json): его можно клонировать прямо
в garrysmod/addons/. Документация, CI и инструменты лежат рядом и исключаются из .gma списком "ignore"
в addon.json (gmad не пропускает .md/.py). Источники:
    аддон      — AETHER_ADDON (по умолчанию живая папка в GMod)
    GitHub     — release/github (README ×3, docs/API ×3, CONTRIBUTING, CHANGELOG, LICENSE, .github)
    инструменты — только переносимые: проверки, генераторы ассетов (без чтения подписок Steam).
"""
import argparse
import json
import os
import shutil
import subprocess

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GMOD = os.environ.get("GMOD_DIR", r"C:\Program Files (x86)\Steam\steamapps\common\GarrysMod")
ADDON = os.environ.get("AETHER_ADDON", os.path.join(GMOD, "garrysmod", "addons", "aether_gaslua"))
GITHUB = os.path.join(ROOT, "release", "github")
OUT = os.path.join(ROOT, "release", "repo")
GMA = os.path.join(ROOT, "release", "aether_gas.gma")

ADDON_DIRS = ["lua", "materials", "models", "sound", "resource", "shaders"]
TOOLS = ["luacheck51.py", "test_bitmath.py", "test_solver_physics.py", "make_models.py", "texgen.py", "import_glb.py", "build_shaders.py", "preview_style.py", "make_smoke_vtf.py",
         "make_release.py", "release_check.py", "make_cover.py", "export_props.py", "blender_scene.py"]
IGNORE = ["*.md", "*.py", "*.yml", "LICENSE", ".git*", ".github/*", "docs/*", "tools/*", "build/*",
          "materialsrc/*", "*.psd", "*.bak", ".vscode/*"]


def copytree(src, dst):
    if os.path.isdir(src):
        shutil.copytree(src, dst, dirs_exist_ok=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--no-gma", action="store_true")
    args = ap.parse_args()

    # Очистить release/repo, но сохранить .git: после git init пересборка не должна стирать историю.
    os.makedirs(OUT, exist_ok=True)
    for name in os.listdir(OUT):
        if name == ".git":
            continue
        p = os.path.join(OUT, name)
        if os.path.isdir(p):
            shutil.rmtree(p)
        else:
            os.remove(p)
    for d in ADDON_DIRS:
        copytree(os.path.join(ADDON, d), os.path.join(OUT, d))
    with open(os.path.join(ADDON, "addon.json"), encoding="utf-8") as f:
        meta = json.load(f)
    meta["ignore"] = IGNORE
    with open(os.path.join(OUT, "addon.json"), "w", encoding="utf-8", newline="\n") as f:
        json.dump(meta, f, indent="\t", ensure_ascii=False)
        f.write("\n")
    copytree(GITHUB, OUT)
    os.makedirs(os.path.join(OUT, "tools"), exist_ok=True)
    for t in TOOLS:
        shutil.copy2(os.path.join(ROOT, "tools", t), os.path.join(OUT, "tools", t))
    copytree(os.path.join(ROOT, "tools", "shaders"), os.path.join(OUT, "tools", "shaders"))   # исходники HLSL
    files = sum(len(fs) for d, _, fs in os.walk(OUT) if ".git" not in d.split(os.sep))
    print(f"repo: {OUT} ({files} files)")

    if args.no_gma:
        return
    gmad = os.path.join(GMOD, "bin", "gmad.exe")
    r = subprocess.run([gmad, "create", "-folder", OUT, "-out", GMA], capture_output=True, text=True, timeout=300)
    print(r.stdout[-2000:])
    if r.returncode != 0 or not os.path.exists(GMA):
        raise SystemExit("gmad failed:\n" + r.stderr[-2000:])
    print(f"gma: {GMA} ({os.path.getsize(GMA) // 1024} KB)")


if __name__ == "__main__":
    main()
