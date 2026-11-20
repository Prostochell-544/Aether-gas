"""Чтение glTF 2.0 / GLB (без сторонних библиотек): меши с мировыми матрицами узлов, UV, нормали,
встроенные PNG-текстуры материалов. Нужно для сторонних моделей под свободной лицензией (CC BY),
которые аддон подключает с указанием автора (см. CREDITS в README).

load_glb(path) → {"meshes": [{"name", "material", "pos" (N,3), "nrm" (N,3), "uv" (N,2), "idx" (M,3)}],
                  "materials": {name: {"baseColor": PIL.Image|None, "normal": ..., "mr": ..., "alpha": bool}},
                  "asset": {...}}
Координаты — мировые, в метрах, как в файле (glTF: Y вверх).
"""
import io
import json
import struct

import numpy as np
from PIL import Image

_COMP = {5120: np.int8, 5121: np.uint8, 5122: np.int16, 5123: np.uint16, 5125: np.uint32, 5126: np.float32}
_NCOMP = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4, "MAT4": 16}


def _node_matrix(n):
    if "matrix" in n:
        return np.array(n["matrix"], float).reshape(4, 4).T          # glTF — по столбцам
    T = np.eye(4)
    if "translation" in n:
        T[:3, 3] = n["translation"]
    R = np.eye(4)
    if "rotation" in n:
        x, y, z, w = n["rotation"]
        R[:3, :3] = [[1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
                     [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
                     [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)]]
    S = np.eye(4)
    if "scale" in n:
        S[0, 0], S[1, 1], S[2, 2] = n["scale"]
    return T @ R @ S


def load_glb(path):
    b = open(path, "rb").read()
    magic, _, _ = struct.unpack_from("<III", b, 0)
    assert magic == 0x46546C67, "not a GLB"
    off, js, binc = 12, None, None
    while off < len(b):
        ln, typ = struct.unpack_from("<II", b, off)
        chunk = b[off + 8:off + 8 + ln]
        if typ == 0x4E4F534A:
            js = json.loads(chunk)
        elif typ == 0x004E4942:
            binc = chunk
        off += 8 + ln

    def view(i):
        bv = js["bufferViews"][i]
        o = bv.get("byteOffset", 0)
        return binc[o:o + bv["byteLength"]], bv.get("byteStride")

    def accessor(i):
        a = js["accessors"][i]
        data, stride = view(a["bufferView"])
        dt = np.dtype(_COMP[a["componentType"]])
        nc = _NCOMP[a["type"]]
        o = a.get("byteOffset", 0)
        if stride and stride != dt.itemsize * nc:
            arr = np.frombuffer(data, dtype=np.uint8)
            out = np.empty((a["count"], nc), dt)
            for k in range(a["count"]):
                out[k] = np.frombuffer(arr[o + k * stride:o + k * stride + dt.itemsize * nc].tobytes(), dt)
            return out
        return np.frombuffer(data, dtype=dt, count=a["count"] * nc, offset=o).reshape(a["count"], nc)

    def image(tex_index):
        if tex_index is None:
            return None
        src = js["textures"][tex_index]["source"]
        data, _ = view(js["images"][src]["bufferView"])
        return Image.open(io.BytesIO(bytes(data)))

    mats = {}
    for m in js.get("materials", []):
        pbr = m.get("pbrMetallicRoughness", {})
        mats[m["name"]] = {
            "baseColor": image(pbr.get("baseColorTexture", {}).get("index")),
            "normal": image(m.get("normalTexture", {}).get("index")),
            "mr": image(pbr.get("metallicRoughnessTexture", {}).get("index")),
            "alpha": m.get("alphaMode") == "BLEND",
        }

    meshes = []

    def walk(ni, parent):
        n = js["nodes"][ni]
        M = parent @ _node_matrix(n)
        if "mesh" in n:
            for pr in js["meshes"][n["mesh"]]["primitives"]:
                at = pr["attributes"]
                pos = accessor(at["POSITION"]).astype(float)
                nrm = accessor(at["NORMAL"]).astype(float) if "NORMAL" in at else np.zeros_like(pos)
                uv = accessor(at["TEXCOORD_0"]).astype(float) if "TEXCOORD_0" in at else np.zeros((len(pos), 2))
                idx = accessor(pr["indices"]).astype(np.int64).reshape(-1, 3) if "indices" in pr \
                    else np.arange(len(pos)).reshape(-1, 3)
                pos = (np.c_[pos, np.ones(len(pos))] @ M.T)[:, :3]
                N3 = np.linalg.inv(M[:3, :3]).T
                nrm = nrm @ N3.T
                nrm /= np.linalg.norm(nrm, axis=1, keepdims=True) + 1e-12
                mat = js["materials"][pr["material"]]["name"] if "material" in pr else "default"
                meshes.append({"name": n.get("name", ""), "material": mat, "pos": pos, "nrm": nrm, "uv": uv, "idx": idx})
        for c in n.get("children", []):
            walk(c, M)

    for root in js["scenes"][js.get("scene", 0)]["nodes"]:
        walk(root, np.eye(4))
    return {"meshes": meshes, "materials": mats, "asset": js.get("asset", {})}
