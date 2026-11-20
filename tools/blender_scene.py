"""Сцены Blender для Workshop: витрина всех пропов и обложки. Запуск (Blender 5.x, без окна):

    "C:\\Program Files\\Blender Foundation\\Blender 5.3\\blender.exe" -b --factory-startup ^
        --python tools/blender_scene.py -- showcase [--render] [--samples N]
    ... -- cover_a | cover_b | cover_c [--render]

Сначала: python -I tools/export_props.py (OBJ моделей → build/blender). Сцена сохраняется в
release/workshop/blender/<сцена>.blend (её можно открыть, подвинуть камеру и рендерить вручную, Cycles);
--render — рендер в release/workshop/blender/<сцена>.png. Единицы: модели в юнитах Source, 1 юнит = 1 дюйм
(0.0254 м). Лицевая сторона моделей (надписи) — +X, поэтому камера смотрит с +X на −X.
"""
import json
import math
import os
import sys

import bpy
from mathutils import Vector

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "build", "blender")
OUT = os.path.join(ROOT, "release", "workshop", "blender")
U = 0.0254   # метров в юните Source

META = json.load(open(os.path.join(SRC, "props.json"), encoding="utf-8"))
TEX = META["tex"]
GAS_COLOR = {   # цвет дыма (как GAS_GLOW в make_models), 0..1
    "smoke": (0.85, 0.86, 0.88), "chlorine": (0.72, 0.80, 0.18), "signal_red": (0.85, 0.16, 0.12),
    "signal_green": (0.20, 0.62, 0.25), "signal_yellow": (0.90, 0.78, 0.18), "signal_violet": (0.50, 0.26, 0.72),
    "signal_orange": (0.92, 0.46, 0.12), "co_smoke": (0.22, 0.20, 0.19), "steam": (0.92, 0.94, 0.97),
}


# -------------------------------------------------------------------------------------------------
# Материалы и модели
# -------------------------------------------------------------------------------------------------
_mats = {}


def material(tex):
    """Материал по имени текстуры (PNG из build/models/tex). Линзы противогаза — стекло."""
    if tex in _mats:
        return _mats[tex]
    m = bpy.data.materials.new(tex)
    m.use_nodes = True
    nt = m.node_tree
    bsdf = nt.nodes.get("Principled BSDF")
    img_path = os.path.join(TEX, tex + ".png")
    if os.path.exists(img_path):
        img = nt.nodes.new("ShaderNodeTexImage")
        img.image = bpy.data.images.load(img_path, check_existing=True)
        img.interpolation = "Cubic"
        nt.links.new(img.outputs["Color"], bsdf.inputs["Base Color"])
        # рельеф из яркости: сколы краски, трафарет — без отдельной карты нормалей
        bump = nt.nodes.new("ShaderNodeBump")
        bump.inputs["Strength"].default_value = 0.25
        bump.inputs["Distance"].default_value = 0.002
        nt.links.new(img.outputs["Color"], bump.inputs["Height"])
        nt.links.new(bump.outputs["Normal"], bsdf.inputs["Normal"])
    bsdf.inputs["Roughness"].default_value = 0.62
    if "lens" in tex:
        bsdf.inputs["Roughness"].default_value = 0.05
        bsdf.inputs["Transmission Weight"].default_value = 0.6
        bsdf.inputs["Base Color"].default_value = (0.12, 0.16, 0.16, 1)
    if any(k in tex for k in ("cylinder", "propane", "grenade", "fan", "vent", "analyzer")):
        bsdf.inputs["Roughness"].default_value = 0.48
    _mats[tex] = m
    return m


_loaded = {}


def model(name):
    """Меш модели (импорт OBJ один раз, дальше — копии данных)."""
    if name not in _loaded:
        bpy.ops.wm.obj_import(filepath=os.path.join(SRC, name + ".obj"), forward_axis="Y", up_axis="Z")
        objs = list(bpy.context.selected_objects)
        bpy.context.view_layer.objects.active = objs[0]
        if len(objs) > 1:
            bpy.ops.object.join()
        o = bpy.context.view_layer.objects.active
        o.name = "_src_" + name
        o.hide_render = o.hide_viewport = True
        for p in o.data.polygons:
            p.use_smooth = True
        _loaded[name] = o
    return _loaded[name]


def place(name, x, y, z=0.0, yaw=0.0, skin=None, pitch=0.0, roll=0.0, scale=1.0, label=None):
    """Экземпляр модели в точке (x, y, z) юнитов; yaw/pitch/roll — градусы; skin — имя текстуры
    (для моделей с одной текстурой) или номер скина из props.json."""
    src = model(name)
    o = bpy.data.objects.new(label or name, src.data.copy())
    bpy.context.collection.objects.link(o)
    o.location = (x * U, y * U, z * U)
    o.rotation_euler = (math.radians(roll), math.radians(pitch), math.radians(yaw))
    o.scale = (U * scale,) * 3
    meta = META["models"][name]
    if isinstance(skin, int):
        skin = meta["skins"][skin]
    for i, slot in enumerate(o.data.materials):
        base = slot.name.split(".")[0]
        tex = skin if (skin and len(meta["mats"]) == 1) else base
        o.data.materials[i] = material(tex)
    return o


# -------------------------------------------------------------------------------------------------
# Окружение: циклорама (пол, плавно переходящий в стену), свет, камера
# -------------------------------------------------------------------------------------------------
def reset():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    _mats.clear()
    _loaded.clear()


def cyclorama(color=(0.11, 0.115, 0.12), size=16.0, back=-1.4, height=6.0, rough=0.85, r=1.2):
    import bmesh
    me = bpy.data.meshes.new("cyclorama")
    bm = bmesh.new()
    steps = 16                            # r — радиус перехода пол → стена; пол плоский до back + r
    prof = [(size, 0.0), (back + r, 0.0)]
    for i in range(1, steps + 1):          # дуга перехода пол → стена
        a = i / steps * math.pi / 2
        prof.append((back + r - math.sin(a) * r, r - math.cos(a) * r))
    prof.append((back, height))
    rows = []
    for y in (-size, size):
        rows.append([bm.verts.new((px, y, pz)) for px, pz in prof])
    for i in range(len(prof) - 1):
        bm.faces.new((rows[0][i], rows[0][i + 1], rows[1][i + 1], rows[1][i]))
    bm.to_mesh(me)
    bm.free()
    for p in me.polygons:
        p.use_smooth = True
    o = bpy.data.objects.new("cyclorama", me)
    bpy.context.collection.objects.link(o)
    m = bpy.data.materials.new("cyclorama")
    m.use_nodes = True
    nt = m.node_tree
    bsdf = nt.nodes["Principled BSDF"]
    bsdf.inputs["Roughness"].default_value = rough
    # бетон: шум по цвету, не плоская заливка
    noise = nt.nodes.new("ShaderNodeTexNoise")
    noise.inputs["Scale"].default_value = 18
    ramp = nt.nodes.new("ShaderNodeValToRGB")
    ramp.color_ramp.elements[0].color = (color[0] * 0.8, color[1] * 0.8, color[2] * 0.8, 1)
    ramp.color_ramp.elements[1].color = (color[0] * 1.25, color[1] * 1.25, color[2] * 1.25, 1)
    nt.links.new(noise.outputs["Fac"], ramp.inputs["Fac"])
    nt.links.new(ramp.outputs["Color"], bsdf.inputs["Base Color"])
    o.data.materials.append(m)
    return o


def area_light(name, loc, target, power, size, color=(1, 1, 1)):
    d = bpy.data.lights.new(name, "AREA")
    d.energy = power
    d.size = size
    d.color = color
    o = bpy.data.objects.new(name, d)
    bpy.context.collection.objects.link(o)
    o.location = loc
    o.visible_camera = False      # сам светильник в кадре не виден
    look_at(o, target)
    return o


def look_at(o, target):
    v = Vector(target) - o.location
    o.rotation_euler = v.to_track_quat("-Z", "Y").to_euler()


def camera(loc, target, lens=40, shift_y=0.0):
    d = bpy.data.cameras.new("camera")
    d.lens = lens
    d.shift_y = shift_y
    o = bpy.data.objects.new("camera", d)
    bpy.context.collection.objects.link(o)
    o.location = loc
    look_at(o, target)
    bpy.context.scene.camera = o
    return o


def world(color=(0.015, 0.016, 0.018), strength=1.0):
    w = bpy.data.worlds.new("world")
    w.use_nodes = True
    bg = w.node_tree.nodes["Background"]
    bg.inputs["Color"].default_value = (*color, 1)
    bg.inputs["Strength"].default_value = strength
    bpy.context.scene.world = w


def render_settings(w, h, samples, engine="CYCLES"):
    sc = bpy.context.scene
    sc.render.resolution_x, sc.render.resolution_y = w, h
    sc.render.resolution_percentage = 100
    sc.render.engine = engine
    if engine == "CYCLES":
        sc.cycles.samples = samples
        sc.cycles.use_denoising = True
        # перекрытые объёмы дыма: каждая грань куба — прозрачный отскок; с запасом, иначе луч обрывается
        sc.cycles.transparent_max_bounces = 128
        sc.cycles.max_bounces = 24
        sc.cycles.volume_bounces = 2
        sc.cycles.volume_step_rate = 0.5
        prefs = bpy.context.preferences.addons.get("cycles")
        if prefs:   # GPU, если есть
            cp = prefs.preferences
            for kind in ("OPTIX", "CUDA", "HIP", "ONEAPI", "METAL"):
                try:
                    cp.compute_device_type = kind
                    cp.get_devices()
                    if any(d.type == kind for d in cp.devices):
                        for d in cp.devices:
                            d.use = True
                        sc.cycles.device = "GPU"
                        break
                except TypeError:
                    continue
    sc.view_settings.view_transform = "AgX"
    sc.view_settings.look = "AgX - Medium High Contrast"
    sc.view_settings.exposure = sc.get("exposure", 0.0)
    sc.render.image_settings.file_format = "PNG"


# -------------------------------------------------------------------------------------------------
# Дым для обложек: объём с шумом (Principled Volume), форма — столб/клуб
# -------------------------------------------------------------------------------------------------
def smoke(name, loc, size, color, density=6.0, seed=0.0, rise=1.0):
    """Клуб дыма: куб с объёмным материалом; плотность = шум × сферическое затухание."""
    bpy.ops.mesh.primitive_cube_add(size=1, location=loc)
    o = bpy.context.active_object
    o.name = name
    o.scale = size
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    nt = m.node_tree
    nt.nodes.remove(nt.nodes["Principled BSDF"])
    out = nt.nodes["Material Output"]
    vol = nt.nodes.new("ShaderNodeVolumePrincipled")
    vol.inputs["Color"].default_value = (*color, 1)
    vol.inputs["Anisotropy"].default_value = 0.3
    coord = nt.nodes.new("ShaderNodeTexCoord")
    # сфера: 1 − |объектные координаты|·2 (куб −0.5..0.5)
    length = nt.nodes.new("ShaderNodeVectorMath")
    length.operation = "LENGTH"
    nt.links.new(coord.outputs["Object"], length.inputs[0])
    fall = nt.nodes.new("ShaderNodeMapRange")
    fall.inputs["From Min"].default_value = 0.5
    fall.inputs["From Max"].default_value = 0.12
    nt.links.new(length.outputs["Value"], fall.inputs["Value"])
    noise = nt.nodes.new("ShaderNodeTexNoise")
    noise.noise_dimensions = "4D"
    noise.inputs["W"].default_value = seed
    noise.inputs["Scale"].default_value = 2.6
    noise.inputs["Detail"].default_value = 8
    noise.inputs["Roughness"].default_value = 0.62
    nt.links.new(coord.outputs["Object"], noise.inputs["Vector"])
    shape = nt.nodes.new("ShaderNodeMapRange")
    shape.inputs["From Min"].default_value = 0.42
    shape.inputs["From Max"].default_value = 0.68
    nt.links.new(noise.outputs["Fac"], shape.inputs["Value"])
    mul = nt.nodes.new("ShaderNodeMath")
    mul.operation = "MULTIPLY"
    nt.links.new(fall.outputs["Result"], mul.inputs[0])
    nt.links.new(shape.outputs["Result"], mul.inputs[1])
    dens = nt.nodes.new("ShaderNodeMath")
    dens.operation = "MULTIPLY"
    dens.inputs[1].default_value = density
    nt.links.new(mul.outputs["Value"], dens.inputs[0])
    nt.links.new(dens.outputs["Value"], vol.inputs["Density"])
    nt.links.new(vol.outputs["Volume"], out.inputs["Volume"])
    o.data.materials.append(m)
    return o


def _math(nt, op, a, b=None, clamp=False):
    n = nt.nodes.new("ShaderNodeMath")
    n.operation = op
    n.use_clamp = clamp
    for i, v in enumerate((a, b)):
        if v is None:
            continue
        if isinstance(v, (int, float)):
            n.inputs[i].default_value = v
        else:
            nt.links.new(v, n.inputs[i])
    return n.outputs[0]


def plume(name, base, height, width, color, seed, density=8.0, lean=(0.0, 0.0), spread=0.7):
    """Столб дыма одним объёмом: узкий у источника, расширяется кверху (радиус ∝ h^spread), клонится
    на lean (доли ширины к верху), края рваные — координаты искажены шумом, внутри — клубы."""
    bx, by, bz = base
    # объём вдвое шире столба (иначе рваный край упирается в грань куба — срез); низ чуть над полом:
    # пол внутри объёма даёт прямоугольное пятно
    # Грани перекрытых объёмов не должны совпадать (Cycles путает вход/выход — столб пропадает или режется):
    # у каждого столба свой малый сдвиг низа и размера.
    j = (sum(map(ord, name)) % 23) * 0.0037
    bz = max(bz, 0.01) + j
    bpy.ops.mesh.primitive_cube_add(size=1, location=(bx + j, by - j, bz + height / 2))
    o = bpy.context.active_object
    o.name = name
    o.scale = (width * 2 + j * 3, width * 2 + j * 2, height + j * 4)
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    nt = m.node_tree
    nt.nodes.remove(nt.nodes["Principled BSDF"])
    vol = nt.nodes.new("ShaderNodeVolumePrincipled")
    vol.inputs["Color"].default_value = (*color, 1)
    vol.inputs["Anisotropy"].default_value = 0.35
    coord = nt.nodes.new("ShaderNodeTexCoord").outputs["Object"]
    # искажение координат крупным шумом: рваный силуэт
    warp = nt.nodes.new("ShaderNodeTexNoise")
    warp.noise_dimensions = "4D"
    warp.inputs["W"].default_value = seed
    warp.inputs["Scale"].default_value = 1.6
    warp.inputs["Detail"].default_value = 3
    metric = nt.nodes.new("ShaderNodeVectorMath")      # объектные координаты → метры (клубы круглые)
    metric.operation = "MULTIPLY"
    metric.inputs[1].default_value = (width * 2, width * 2, height)
    nt.links.new(coord, metric.inputs[0])
    nt.links.new(metric.outputs[0], warp.inputs["Vector"])
    centered = nt.nodes.new("ShaderNodeVectorMath")
    centered.operation = "SUBTRACT"
    centered.inputs[1].default_value = (0.5, 0.5, 0.5)
    nt.links.new(warp.outputs["Color"], centered.inputs[0])
    scaled = nt.nodes.new("ShaderNodeVectorMath")
    scaled.operation = "SCALE"
    scaled.inputs["Scale"].default_value = 0.12
    nt.links.new(centered.outputs[0], scaled.inputs[0])
    pos = nt.nodes.new("ShaderNodeVectorMath")
    pos.operation = "ADD"
    nt.links.new(coord, pos.inputs[0])
    nt.links.new(scaled.outputs[0], pos.inputs[1])
    sep = nt.nodes.new("ShaderNodeSeparateXYZ")
    nt.links.new(pos.outputs[0], sep.inputs[0])
    h = _math(nt, "ADD", sep.outputs["Z"], 0.5, clamp=True)                   # 0 у источника .. 1 вверху
    hp = _math(nt, "POWER", h, spread)
    wz = _math(nt, "ADD", _math(nt, "MULTIPLY", hp, 0.21), 0.025)             # радиус столба на высоте (≤ 0.24 куба)
    h2 = _math(nt, "MULTIPLY", h, h)
    x = _math(nt, "SUBTRACT", sep.outputs["X"], _math(nt, "MULTIPLY", h2, lean[0] * 0.5))
    y = _math(nt, "SUBTRACT", sep.outputs["Y"], _math(nt, "MULTIPLY", h2, lean[1] * 0.5))
    r = _math(nt, "SQRT", _math(nt, "ADD", _math(nt, "MULTIPLY", x, x), _math(nt, "MULTIPLY", y, y)))
    prof = _math(nt, "SUBTRACT", 1.0, _math(nt, "DIVIDE", r, wz), clamp=True)
    vfade = _math(nt, "MULTIPLY", _math(nt, "MULTIPLY", h, 12.0, clamp=True),
                  _math(nt, "MULTIPLY", _math(nt, "SUBTRACT", 1.0, h), 2.5, clamp=True))
    # клубы внутри
    det = nt.nodes.new("ShaderNodeTexNoise")
    det.noise_dimensions = "4D"
    det.inputs["W"].default_value = seed + 7.3
    det.inputs["Scale"].default_value = 3.2
    det.inputs["Detail"].default_value = 12
    det.inputs["Roughness"].default_value = 0.65
    metric2 = nt.nodes.new("ShaderNodeVectorMath")
    metric2.operation = "MULTIPLY"
    metric2.inputs[1].default_value = (width * 2, width * 2, height)
    nt.links.new(pos.outputs[0], metric2.inputs[0])
    nt.links.new(metric2.outputs[0], det.inputs["Vector"])
    shape = nt.nodes.new("ShaderNodeMapRange")
    shape.inputs["From Min"].default_value = 0.47
    shape.inputs["From Max"].default_value = 0.6
    shape.inputs["To Min"].default_value = 0.08     # между клубами — лёгкая дымка, клубы плотные
    nt.links.new(det.outputs["Fac"], shape.inputs["Value"])
    d = _math(nt, "MULTIPLY", _math(nt, "MULTIPLY", _math(nt, "POWER", prof, 0.6), vfade), shape.outputs["Result"])
    d = _math(nt, "MULTIPLY", d, density)
    nt.links.new(d, vol.inputs["Density"])
    nt.links.new(vol.outputs["Volume"], nt.nodes["Material Output"].inputs["Volume"])
    o.data.materials.append(m)
    return o


# -------------------------------------------------------------------------------------------------
# Сцены
# -------------------------------------------------------------------------------------------------
def scene_showcase():
    """Все пропы в три ряда: баллоны сзади, крупные предметы посередине, мелочь спереди."""
    reset()
    world((0.02, 0.021, 0.024), 1.0)
    # стена дальше и переход короче: задний ряд стоит на плоском полу (на изгибе предметы «тонули»)
    cyclorama(color=(0.055, 0.058, 0.062), back=-2.05, r=0.45)
    # задний ряд: баллоны пяти видов, вентилятор, воздуходувка, пропан
    row = [("chlorine", 0), ("smoke", 1), ("methane", 2), ("sarin", 3), ("co2", 4), ("signal_red", 0),
           ("steam", 2), ("ammonia", 1)]
    y0 = -len(row) * 11 / 2 + 5.5
    for i, (gas, sk) in enumerate(row):
        place(f"gas_cylinder_{gas}", -50, y0 + i * 11, yaw=(i % 3 - 1) * 8, skin=sk)
    place("exhaust_fan", -46, y0 - 26, yaw=25, skin="fan_su")
    place("exhaust_fan", -46, y0 + len(row) * 11 + 15, yaw=-25, skin="fan_blower_nato", label="blower")
    # решётки вытяжки — на стене над баллонами, как в помещении
    place("gas_vent", -2.05 / U + 12.5, -26, z=54, skin="vent_su_in", label="vent_in")
    place("gas_vent", -2.05 / U + 12.5, 26, z=54, skin="vent_nato_out", label="vent_out")
    # средний ряд
    place("gas_emitter", -24, -42, yaw=20)
    place("propane_tank", -26, -24, yaw=-10)
    place("hazmat_suit", -22, -4, yaw=8)
    place("gas_sprayer", -20, 20, z=5.1, yaw=-30)
    place("hose_nozzle", -14, 38, z=1.6, yaw=40)
    # передний ряд: противогаз, фильтр, анализатор, гранаты, фаеры, антидоты
    place("gasmask", 12, -50, z=7.6, yaw=-20)
    place("gas_filter", 16, -38, yaw=30)
    place("gas_analyzer", 8, -29, yaw=-15)
    for i, sk in enumerate(("grenade_su_chlorine", "grenade_nato_signal_red", "grenade_tear_gas")):
        place("gas_grenade", 14, -18 + i * 5.5, yaw=-10 + i * 10, skin=sk)
    for i, sk in enumerate(("flare_signal_green", "flare_nato_signal_orange", "flare_classic_signal_violet")):
        place("signal_flare", 10, 2 + i * 5, z=0.7, yaw=i * 25, skin=sk)
    for i, kind in enumerate(("atropine", "eyewash", "oxygen", "decon")):
        place(f"antidote_{kind}", 18, 22 + i * 7, yaw=-15, skin=f"antidote_{kind}")
        place(f"antidote_{kind}", 6, 24 + i * 7, yaw=10, skin=f"antidote_{kind}_nato", label=f"{kind}_nato")
    # свет: ключевой сверху-слева, заполняющий справа, контровой сзади (обводка по краям)
    area_light("key", (2.2, -2.4, 2.6), (-0.6, 0, 0.3), 900, 2.5, (1.0, 0.95, 0.88))
    area_light("fill", (2.4, 2.6, 1.2), (-0.6, 0, 0.3), 260, 3.0, (0.85, 0.9, 1.0))
    area_light("rim", (-2.2, 0.4, 2.4), (0.0, 0, 0.2), 500, 2.0, (0.9, 0.95, 1.0))
    camera((3.3, 0, 1.35), (-0.55, 0, 0.5), lens=32)
    bpy.context.scene["exposure"] = -0.6


def cover_base(floor=(0.018, 0.019, 0.021), exposure=-0.9):
    reset()
    world((0.004, 0.0045, 0.005), 1.0)
    cyclorama(color=floor, back=-2.6, height=8)
    bpy.context.scene["exposure"] = exposure


def scene_cover_a():
    """A: противогаз ГП-7 крупно, за ним столбы хлора и белого дыма; внизу место под логотип."""
    cover_base()
    place("hazmat_suit", 0, 0, yaw=-8, scale=2.0)               # ящик ОЗК — подставка
    place("gasmask", -1, 0, z=11.2 + 7.6 * 1.6, yaw=-30, pitch=-6, scale=1.6)
    place("gas_grenade", 10, -17, yaw=-12, skin="grenade_su_chlorine", scale=1.6)
    plume("chlorine", (-1.0, -0.55, 0.0), 1.9, 1.5, GAS_COLOR["chlorine"], 1.0, density=16, lean=(0.0, 0.25))
    plume("white", (-1.25, 0.55, 0.0), 2.1, 1.6, GAS_COLOR["smoke"], 2.2, density=14, lean=(0.0, -0.2))
    plume("red", (-1.6, 0.0, 0.0), 2.2, 1.4, GAS_COLOR["signal_red"], 3.4, density=12, lean=(0.2, 0.15))
    area_light("key", (1.3, -1.5, 1.7), (0, 0, 0.7), 420, 1.2, (1.0, 0.93, 0.84))
    area_light("rim", (-1.0, 1.3, 1.8), (0, 0, 0.75), 380, 1.2, (0.75, 0.88, 1.0))
    area_light("smoke_back", (-2.4, 0, 2.2), (-1.2, 0, 1.4), 500, 1.5, (1.0, 1.0, 1.0))
    camera((2.1, 0.05, 0.75), (0, 0.05, 0.36), lens=42)   # внизу место под логотип


def scene_cover_b():
    """B: три баллона (СССР, НАТО, современный) со столбами дыма своих цветов; логотип сверху."""
    cover_base()
    for y, gas, sk, lean in ((-15, "chlorine", 0, (0, -0.3)), (0, "smoke", 1, (0, 0.05)), (15, "signal_red", 2, (0, 0.3))):
        place(f"gas_cylinder_{gas}", 0, y, yaw=(y / 15) * -12, skin=sk)
        plume(gas, (0, y * U, 44.5 * U), 1.15, 0.85, GAS_COLOR[gas], y * 0.1 + 3, density=16, lean=lean, spread=0.55)
    area_light("key", (1.6, -1.4, 1.6), (0, 0, 0.5), 420, 1.4, (1.0, 0.94, 0.86))
    area_light("rim", (-1.2, 0, 2.4), (0, 0, 1.0), 500, 1.6, (0.8, 0.88, 1.0))
    area_light("smoke_back", (-2.4, 0, 2.4), (0, 0, 1.6), 450, 1.5)
    camera((2.6, 0, 0.9), (0, 0, 0.98), lens=36)


def scene_cover_c():
    """C: на полу горят фаеры трёх цветов, граната НАТО, анализатор; дым поднимается и смешивается."""
    cover_base(exposure=-0.2)
    flares = (("red", -2, -8, 30, "flare_signal_red", (1, 0.22, 0.12)),
              ("green", 4, 7, -50, "flare_nato_signal_green", (0.25, 1, 0.3)),
              ("violet", -9, 16, 100, "flare_classic_signal_violet", (0.6, 0.3, 1)))
    for col, x, y, yaw, sk, glow in flares:
        place("signal_flare", x, y, z=0.9, pitch=90, yaw=yaw, skin=sk)
        d = bpy.data.lights.new("glow_" + col, "POINT")
        d.energy, d.color, d.shadow_soft_size = 30, glow, 0.02
        lo = bpy.data.objects.new("glow_" + col, d)
        bpy.context.collection.objects.link(lo)
        lo.location = (x * U, y * U, 2.5 * U)
        plume("smoke_" + col, (x * U - 0.05, y * U, 0.0), 1.6, 0.9, GAS_COLOR["signal_" + col], len(col) * 1.3,
              density=14, lean=(-0.35, 0.1 * (y / 10)), spread=0.6)
    place("gas_grenade", 12, -4, yaw=-20, skin="grenade_nato_smoke")
    place("gas_analyzer", 13, 13, yaw=-35)
    place("gasmask", 4, -22, z=6.5, yaw=-40)
    area_light("key", (1.0, -1.1, 1.3), (0, 0, 0.1), 140, 1.2, (1.0, 0.92, 0.84))
    area_light("rim", (-1.6, 0, 1.6), (0, 0, 0.6), 600, 2.4, (0.8, 0.88, 1.0))
    camera((1.3, -0.12, 0.62), (-0.15, 0.05, 0.36), lens=30)


SCENES = {"showcase": (scene_showcase, 2560, 1440), "cover_a": (scene_cover_a, 1024, 1024),
          "cover_b": (scene_cover_b, 1024, 1024), "cover_c": (scene_cover_c, 1024, 1024)}


def main():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else ["showcase"]
    name = argv[0]
    samples = int(argv[argv.index("--samples") + 1]) if "--samples" in argv else 128
    scale = int(argv[argv.index("--scale") + 1]) if "--scale" in argv else 100
    fn, w, h = SCENES[name]
    fn()
    render_settings(w, h, samples)
    bpy.context.scene.render.resolution_percentage = scale
    os.makedirs(OUT, exist_ok=True)
    bpy.ops.wm.save_as_mainfile(filepath=os.path.join(OUT, name + ".blend"), relative_remap=False)
    print("saved:", os.path.join(OUT, name + ".blend"), flush=True)
    if "--render" in argv:
        bpy.context.scene.render.filepath = os.path.join(OUT, name + ".png")
        bpy.ops.render.render(write_still=True)
        print("rendered:", bpy.context.scene.render.filepath, flush=True)


if __name__ == "__main__":
    main()
