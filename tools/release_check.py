"""Предрелизная проверка аддона Aether (только чтение).

    python -I tools/release_check.py

Проверяет то, что ломается только в игре и не ловится luacheck:
  • каждый .lua в lua/aether_gas подключён в autorun (AddCSLuaFile + include, в нужном списке);
  • у каждой энтити/оружия/тулгана есть AddCSLuaFile() (иначе клиент её не получит);
  • все строковые пути "models/...mdl", Material("..."), "entities/*.png" из кода существуют в аддоне
    или в базовой игре (hl2/garrysmod vpk не проверяются — только пути аддона models/aether, materials/aether);
  • все C.NET_* регистрируются util.AddNetworkString;
  • у каждого Spawnable-класса и пресета спавн-меню есть иконка materials/entities/<имя>.png;
  • addon.json: валидный JSON, тип и теги из допустимых gmad;
  • версия в sh_registry совпадает с CHANGELOG.
Код возврата 1 при ошибках.
"""
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GMOD = os.environ.get("GMOD_DIR", r"C:\Program Files (x86)\Steam\steamapps\common\GarrysMod")
# клон репозитория: аддон — сам репозиторий; рабочая папка автора: живой аддон в GMod
ADDON = os.environ.get("AETHER_ADDON") or (ROOT if os.path.exists(os.path.join(ROOT, "addon.json"))
                                           else os.path.join(GMOD, "garrysmod", "addons", "aether_gaslua"))
LUA = os.path.join(ADDON, "lua")

errors, notes = [], []


def err(msg):
    errors.append(msg)


def read(p):
    with open(p, encoding="utf-8") as f:
        return f.read()


def lua_files(sub):
    out = []
    for d, _, fs in os.walk(os.path.join(LUA, sub)):
        for f in fs:
            if f.endswith(".lua"):
                out.append(os.path.relpath(os.path.join(d, f), LUA).replace("\\", "/"))
    return sorted(out)


# 1. Подключение модулей
init = read(os.path.join(LUA, "autorun", "aether_gas_init.lua"))
lists = {}
for name in ("SHARED_FILES", "SERVER_FILES", "CLIENT_FILES"):
    m = re.search(name + r"\s*=\s*\{(.*?)\}", init, re.S)
    lists[name] = re.findall(r'"([^"]+)"', m.group(1)) if m else []
listed = {f: n for n, fs in lists.items() for f in fs}
for f in lua_files("aether_gas"):
    if f not in listed:
        err(f"module not loaded by autorun: {f}")
    else:
        want = {"shared": "SHARED_FILES", "server": "SERVER_FILES", "client": "CLIENT_FILES"}[f.split("/")[1]]
        if listed[f] != want:
            err(f"{f} is in {listed[f]}, expected {want}")
for f in listed:
    if not os.path.exists(os.path.join(LUA, f)):
        err(f"autorun lists missing file: {f}")

# 2. AddCSLuaFile в энтити/оружии/тулганах
for f in lua_files("entities") + lua_files("weapons"):
    src = read(os.path.join(LUA, f))
    if "AddCSLuaFile()" not in src and "/stools/" not in f:
        err(f"no AddCSLuaFile(): {f}")

# 3. Ресурсы
all_lua = {f: read(os.path.join(LUA, f)) for f in lua_files("")}
for f, src in all_lua.items():
    for mdl in re.findall(r'"(models/aether/[^"]+\.mdl)"', src):
        if not os.path.exists(os.path.join(ADDON, mdl)):
            err(f"{f}: missing model {mdl}")
    for mat in re.findall(r'Material\("([^"]+)"\)', src):
        if mat.startswith(("aether/", "models/aether/")):
            base = os.path.join(ADDON, "materials", mat)
            if not (os.path.exists(base + ".vmt") or os.path.exists(base)):
                err(f"{f}: missing material {mat}")
        elif mat.startswith("entities/") and not os.path.exists(os.path.join(ADDON, "materials", mat)):
            err(f"{f}: missing icon {mat}")

# 4. Сетевые сообщения
reg = read(os.path.join(LUA, "aether_gas", "shared", "sh_registry.lua"))
nets = set(re.findall(r"C\.(NET_[A-Z_]+)\s*=", reg))
added = set(re.findall(r"util\.AddNetworkString\(C\.(NET_[A-Z_]+)\)", reg))
for n in sorted(nets - added):
    err(f"net message never registered: {n}")
used = set()
for src in all_lua.values():
    used |= set(re.findall(r"C\.(NET_[A-Z_]+)", src))
for n in sorted(used - nets):
    err(f"net message used but not defined: {n}")

# 5. Иконки спавн-меню
icons = os.path.join(ADDON, "materials", "entities")
for f, src in all_lua.items():
    if not f.startswith(("entities/", "weapons/")) or "/stools/" in f:
        continue
    cls = os.path.splitext(os.path.basename(f))[0]
    if re.search(r"(ENT|SWEP)\.Spawnable\s*=\s*true", src) and not os.path.exists(os.path.join(icons, cls + ".png")):
        err(f"spawnable {cls} has no icon materials/entities/{cls}.png")
base_gases = re.findall(r'"([a-z0-9_]+)"', re.search(r"AetherGas\.BaseGases\s*=\s*\{(.*?)\}", reg, re.S).group(1))
for g in base_gases + ["plain"]:
    if not os.path.exists(os.path.join(icons, f"aether_cylinder_{g}.png")):
        err(f"missing cylinder preset icon aether_cylinder_{g}.png")

# 6. addon.json
meta = json.loads(read(os.path.join(ADDON, "addon.json")))
TYPES = {"gamemode", "map", "weapon", "vehicle", "npc", "entity", "tool", "effects", "model", "servercontent"}
TAGS = {"fun", "roleplay", "scenic", "movie", "realism", "cartoon", "water", "comic", "build"}
if meta.get("type") not in TYPES:
    err(f"addon.json type {meta.get('type')!r} not accepted by gmad")
bad = [t for t in meta.get("tags", []) if t not in TAGS]
if bad or not 1 <= len(meta.get("tags", [])) <= 2:
    err(f"addon.json tags must be 1-2 of {sorted(TAGS)}: {meta.get('tags')}")

# 7. Версия
ver = re.search(r'AetherGas\.Version\s*=\s*"([^"]+)"', reg).group(1)
cl = os.path.join(ROOT, "CHANGELOG.md")
if not os.path.exists(cl):
    cl = os.path.join(ROOT, "release", "github", "CHANGELOG.md")
if os.path.exists(cl) and f"## {ver}" not in read(cl):
    err(f"CHANGELOG has no section for version {ver}")
notes.append(f"version {ver}, {len(all_lua)} lua files, {len(base_gases)} base gases")

# 8. Отладочный вывод, забытый в коде
for f, src in all_lua.items():
    for i, line in enumerate(src.splitlines(), 1):
        if re.match(r"\s*print\(", line) or "PrintTable(" in line:
            notes.append(f"debug print? {f}:{i}: {line.strip()[:80]}")

for n in notes:
    print("note ", n)
for e in errors:
    print("ERROR", e)
print("release check:", "FAILED" if errors else "OK", f"({len(errors)} errors)")
sys.exit(1 if errors else 0)
