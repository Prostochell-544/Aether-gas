"""Сборка пиксельных шейдеров Aether для GMod (материал screenspace_general, параметр $pixshader).

    python -I tools/build_shaders.py [имя ...]

Исходники: tools/shaders/<имя>.hlsl (одна точка входа main, без комбинаций). Компилятор — fxc.exe из Windows SDK
(D3D9-профиль по суффиксу имени: *_ps20b, *_vs20, *_ps30, *_vs30). Результат — shaders/fxc/<имя>.vcs в аддоне.

Формат VCS v6 (как у шейдеров Source 2013 без комбинаций; сверено с шейдерами из Workshop):
    заголовок 7×uint32: версия 6, всего комбинаций 1, динамических 1, флаги 0, маска centroid 0,
                        статических записей 2 (комбинация 0 + страж), CRC32 исходника;
    статические записи 2×(uint32 id, uint32 смещение): (0, 48), (0xFFFFFFFF, размер файла);
    uint32 число дубликатов = 0;
    блок: uint32 (размер | 0x40000000 — сжато LZMA), заголовок Valve LZMA ('LZMA', исходный размер,
          сжатый размер, 5 байт свойств), данные LZMA1;
          внутри: uint32 id динамической комбинации (0), uint32 размер байткода, байткод;
    uint32 0xFFFFFFFF — конец блоков.
Проверка: собранный файл распаковывается обратно и байткод сверяется с выходом fxc.
"""
import glob
import lzma
import os
import struct
import subprocess
import sys
import zlib

TOOLS = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(TOOLS, "shaders")
_REPO = os.path.dirname(TOOLS)
ADDON = os.environ.get("AETHER_ADDON") or (_REPO if os.path.exists(os.path.join(_REPO, "addon.json")) else
                                           r"C:\Program Files (x86)\Steam\steamapps\common\GarrysMod\garrysmod\addons\aether_gaslua")
OUT = os.path.join(ADDON, "shaders", "fxc")
BUILD = os.path.join(_REPO, "build", "shaders")


def find_fxc():
    env = os.environ.get("FXC")
    if env and os.path.exists(env):
        return env
    cands = sorted(glob.glob(r"C:\Program Files (x86)\Windows Kits\10\bin\10.*\x64\fxc.exe"), reverse=True)
    if not cands:
        sys.exit("fxc.exe не найден: установите Windows SDK или задайте переменную FXC")
    return cands[0]


PROFILES = {"_ps30": "ps_3_0", "_ps20b": "ps_2_b", "_vs20": "vs_2_0", "_vs30": "vs_3_0"}


def profile_of(name):
    """Профиль по суффиксу имени. В GMod рабочая пара — vs_2_0 + ps_2_b: ps_3_0 со стандартным вершинным
    шейдером screenspace_general (вторая версия) молча не рисует (проверено в игре)."""
    for suf, prof in PROFILES.items():
        if name.endswith(suf):
            return prof
    sys.exit(f"{name}: имя должно оканчиваться на один из {sorted(PROFILES)}")


LZMA_FILTER = {"id": lzma.FILTER_LZMA1, "lc": 3, "lp": 0, "pb": 2, "dict_size": 1 << 24}


def pack_vcs(bytecode, crc):
    inner = struct.pack("<II", 0, len(bytecode)) + bytecode
    comp = lzma.compress(inner, format=lzma.FORMAT_RAW, filters=[LZMA_FILTER])
    props = bytes([(LZMA_FILTER["pb"] * 5 + LZMA_FILTER["lp"]) * 9 + LZMA_FILTER["lc"]]) + struct.pack("<I", LZMA_FILTER["dict_size"])
    block = b"LZMA" + struct.pack("<II", len(inner), len(comp)) + props + comp
    data_off = 28 + 16 + 4
    total = data_off + 4 + len(block) + 4
    out = struct.pack("<7I", 6, 1, 1, 0, 0, 2, crc)
    out += struct.pack("<2I", 0, data_off) + struct.pack("<2I", 0xFFFFFFFF, total)
    out += struct.pack("<I", 0)
    out += struct.pack("<I", len(block) | 0x40000000) + block
    out += struct.pack("<I", 0xFFFFFFFF)
    assert len(out) == total
    return out


def unpack_vcs(b):
    """Распаковать VCS с одной комбинацией (проверка сборки и чтение чужих шейдеров)."""
    ver, total, dyn, _, _, nstatic, _ = struct.unpack_from("<7I", b, 0)
    assert ver == 6 and nstatic == 2, (ver, nstatic)
    _, off = struct.unpack_from("<2I", b, 28)
    blk, = struct.unpack_from("<I", b, off)
    size = blk & 0x3FFFFFFF
    data = b[off + 4: off + 4 + size]
    assert data[:4] == b"LZMA"
    actual = struct.unpack_from("<I", data, 4)[0]
    p = data[12:17]
    lc, rem = p[0] % 9, p[0] // 9
    raw = lzma.LZMADecompressor(lzma.FORMAT_RAW, filters=[{"id": lzma.FILTER_LZMA1, "lc": lc, "lp": rem % 5,
                                "pb": rem // 5, "dict_size": struct.unpack_from("<I", p, 1)[0]}]).decompress(data[17:], max_length=actual)
    combo, n = struct.unpack_from("<II", raw, 0)
    assert combo == 0 and b[-4:] == b"\xff\xff\xff\xff"
    return raw[8:8 + n]


def build(name, fxc):
    src = os.path.join(SRC, name + ".hlsl")
    os.makedirs(BUILD, exist_ok=True)
    obj = os.path.join(BUILD, name + ".bin")
    r = subprocess.run([fxc, "/nologo", "/T", profile_of(name), "/E", "main", "/O3", "/Fo", obj, src],
                       capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f"fxc {name}:\n{r.stdout}\n{r.stderr}")
    code = open(obj, "rb").read()
    vcs = pack_vcs(code, zlib.crc32(open(src, "rb").read()) & 0xFFFFFFFF)
    assert unpack_vcs(vcs) == code, "распаковка не совпала с байткодом"
    os.makedirs(OUT, exist_ok=True)
    with open(os.path.join(OUT, name + ".vcs"), "wb") as f:
        f.write(vcs)
    print(f"{name}.vcs: {len(code)} B bytecode -> {len(vcs)} B")


if __name__ == "__main__":
    fxc = find_fxc()
    names = sys.argv[1:] or sorted(os.path.splitext(os.path.basename(p))[0] for p in glob.glob(os.path.join(SRC, "*.hlsl")))
    for n in names:
        build(n, fxc)
