-- lua/aether_gas/client/cl_mesher.lua
--[[
    Рендер газа: один кэшированный IMesh на слот пула (чанк 8³).

    Каждая непустая ячейка — мягкий квад, развёрнутый к камере на момент сборки:
      • размер 1.5–2.4 вокселя: соседние спрайты перекрываются, «кубичность» сетки исчезает;
      • детерминированный сдвиг и поворот от ключа ячейки (key % 97/89/83, 8 углов) — без повторов узора;
      • у закрытых граней центр отодвигается от стены, альфа падает — нет резкого среза об геометрию;
      • альфа = min(1, c)·opacity, цвет газа × освещение чанка (render.GetLightColor, один вызов на сборку);
      • внутри чанка квады выдаются от дальних к ближним по знаку взгляда по каждой оси.
    Каждая ячейка — SUB (4) клубов в узлах подсетки 2×2×2 + стелющийся клуб у пола.
    Вершин на чанк не больше 512·5·4 = 10 240 — в шесть раз меньше лимита IMesh (65 535).

    Пересборка: слот грязный (его менял солвер) или камера повернулась больше чем на ~20° от
    ориентации при сборке. Бюджет — aether_mesh_budget мс на кадр, ближние чанки первыми.

    Рисование идёт из PostDrawTranslucentRenderables, а не из сущности: движок не отсекает облако по
    чужим render bounds, поэтому SetRenderBounds не нужен — свой frustum/дистанционный отсев ниже.
    Чанки сортируются от дальних к ближним (прозрачность).
]]

local AetherGas = AetherGas
local Spatial   = AetherGas.Spatial
local Solver    = AetherGas.Solver
local P         = AetherGas.GasParams

local band, rshift = bit.band, bit.rshift
local min, sqrt, abs = math.min, math.sqrt, math.abs
local SysTime = SysTime

local Pool = Spatial.Pool
local Collision = Spatial.Collision
local Gas, Conc = Spatial.Gas, Spatial.Conc
local slotKey, slotDirty = Pool.slotKey, Pool.slotDirty
local FACE_BLOCK_X = Spatial.FACE_BLOCK_X
local Popac = P.Opacity

local cvDraw   = CreateClientConVar("aether_draw", "1", true, false, "Aether: draw gas clouds (0/1).", 0, 1)
local cvDist   = CreateClientConVar("aether_draw_distance", "6000", true, false, "Aether: gas draw distance, units.", 500, 30000)
local cvBudget = CreateClientConVar("aether_mesh_budget", "1.5", true, false, "Aether: mesh rebuild time per frame, ms.", 0.25, 8)

-- Собственная текстура аддона (tools/make_smoke_vtf.py main16): атлас 4×4 — 16 разных клубов с внутренним
-- рельефом без направленного света (направление задаёт меш, см. «объём клуба»). UnlitGeneric с
-- $vertexcolor/$vertexalpha. Стоковой particle/smokesprites_* в базовом GMod нет — была «шахматка».
local MAT = Material("aether/smoke_puff4")
-- «Ультра»: облака рисуются своим шейдером (tools/shaders/aether_smoke_*.hlsl) — клуб гаснет попиксельно у
-- поверхностей по глубине кадра. Меш тот же; меняется только материал. Глубина сцены лежит в альфе
-- _rt_ResolvedFullFrameDepth: aether_ultra_depth — сколько юнитов соответствует альфе 1.0 (калибровка),
-- aether_ultra_fade — ширина затухания у поверхности, юниты.
local cvUltra = CreateClientConVar("aether_ultra", "1", true, false, "Aether: Ultra smoke shader (soft contact with surfaces).", 0, 1)
local cvUltraDepth = CreateClientConVar("aether_ultra_depth", "192", true, false, "Aether: Ultra depth range, units per depth alpha 1.0.", 64, 65536)
local cvUltraFade = CreateClientConVar("aether_ultra_fade", "24", true, false, "Aether: Ultra soft fade near surfaces, units.", 1, 200)
local cvUltraMotion = CreateClientConVar("aether_ultra_motion", "1", true, false, "Aether: Ultra billowing motion strength (0 = still).", 0, 3)
local ULTRA = CreateMaterial("aether_smoke_ultra", "screenspace_general", {
    ["$pixshader"] = "aether_smoke_ps20b",
    ["$vertexshader"] = "aether_smoke_vs20",
    ["$basetexture"] = "aether/smoke_puff4",
    ["$texture1"] = "_rt_ResolvedFullFrameDepth",
    ["$vertextransform"] = 1,
    ["$vertexcolor"] = 1,
    ["$alpha_blend"] = 1,
    ["$linearwrite"] = 1,
})

--- Материал облаков на этот кадр: «Ультра» (обновить глубину кадра и константы) или обычный спрайтовый.
-- screenspace_general сам не смешивает по альфе (квады рисовались непрозрачными — «белое пятно»): для «Ультры»
-- смешивание и отключение записи глубины задаются вручную на время отрисовки облаков (UltraBegin/UltraEnd).
-- Поддержка «Ультры»: DirectX 9 (шейдеры vs_2_0 + ps_2_b), файлы шейдеров на месте, материал создался.
-- Нет — облака рисуются обычным спрайтовым материалом, без ошибок и без настройки игроком.
local ultraOK
local function UltraSupported()
    if ultraOK == nil then
        ultraOK = render.GetDXLevel() >= 90 and render.SupportsPixelShaders_2_0() and render.SupportsVertexShaders_2_0()
            and file.Exists("shaders/fxc/aether_smoke_ps20b.vcs", "GAME") and file.Exists("shaders/fxc/aether_smoke_vs20.vcs", "GAME")
            and not ULTRA:IsError()
        if not ultraOK then
            MsgC(Color(120, 200, 255), "[Aether] ", color_white, "Ultra smoke is not supported here (needs DirectX 9 shaders); using regular smoke.\n")
        end
    end
    return ultraOK
end
AetherGas.UltraSupported = UltraSupported

local function DrawMaterial()
    if not cvUltra:GetBool() or not UltraSupported() then return MAT, false end
    render.UpdateFullScreenDepthTexture()
    ULTRA:SetFloat("$c0_x", cvUltraDepth:GetFloat())
    ULTRA:SetFloat("$c0_y", 1 / cvUltraFade:GetFloat())
    ULTRA:SetFloat("$c0_z", 0.5 / ScrW())
    ULTRA:SetFloat("$c0_w", 0.5 / ScrH())
    return ULTRA, true
end

-- Движение клубов: время t и сила a передаются вершинному шейдеру переносом матрицы модели (t, a, 0) —
-- шейдер восстанавливает их из разницы cModelViewProj и cViewProj (aether_smoke_vs20.hlsl). Время периодично:
-- период 2π·20 с, частоты шейдера кратны 0.05 — переход через период без рывка.
local MOTION_PERIOD = 2 * math.pi * 20
local MotionMatrix, MotionVec = Matrix(), Vector(0, 0, 0)

local function UltraBegin()
    render.OverrideBlend(true, BLEND_SRC_ALPHA, BLEND_ONE_MINUS_SRC_ALPHA, BLENDFUNC_ADD)
    render.OverrideDepthEnable(true, false)
    MotionVec:SetUnpacked(RealTime() % MOTION_PERIOD, cvUltraMotion:GetFloat(), 0)
    MotionMatrix:SetTranslation(MotionVec)
    cam.PushModelMatrix(MotionMatrix)
end

local function UltraEnd()
    cam.PopModelMatrix()
    render.OverrideDepthEnable(false, false)
    render.OverrideBlend(false)
end
-- Объём клуба: верхние углы квада светлее, нижние темнее (свет сверху), доля яркости на полуразмер.
local TOP_LIGHT = 0.3
-- Самозатенение: газ в двух ячейках над текущей затемняет её (облако светлое сверху, тёмное внутри и снизу).
local SELF_SHADOW = 0.45
-- Цветной динамический свет (фаеры, огонь, вспышки, фонарики, чужие dlight): render.ComputeDynamicLighting
-- в углах чанка; чанки с таким светом пересобираются DYN_RATE раз в секунду (свет мигает и гаснет).
local DYN_GAIN, DYN_MIN, DYN_RATE, DYN_PROBE = 1.8, 0.02, 10, 0.25
-- Видимая плотность: альфа = min(1, c·opacity·DENSITY_GAIN). Смок держит c ≈ cohesion (0.45) →
-- спрайт непрозрачен; хлор при c ≈ 0.3 → ~0.6, т. е. облако «густое», а тонкий край просвечивает.
local DENSITY_GAIN = 2.3

AetherGas.Mesher = AetherGas.Mesher or {}
local M = AetherGas.Mesher
M.Meshes  = M.Meshes or {}   -- [slot] = IMesh
M.MeshCk  = M.MeshCk or {}   -- [slot] = chunkKey, для которого собран меш
M.FwdX    = M.FwdX or {}     -- [slot] = направление взгляда при сборке
M.FwdY    = M.FwdY or {}
M.FwdZ    = M.FwdZ or {}
M.Stats   = M.Stats or { built = 0, drawn = 0, buildMs = 0 }
M.EyeX    = M.EyeX or {}     -- [slot] = позиция камеры при сборке (затухание спрайтов у камеры)
M.EyeY    = M.EyeY or {}
M.EyeZ    = M.EyeZ or {}
M.Dyn     = M.Dyn or {}      -- [slot] = в чанке был динамический свет при сборке
M.BuiltAt = M.BuiltAt or {}  -- [slot] = RealTime() сборки
M.Coded   = M.Coded or {}    -- [slot] = меш собран с кодами течения (под «Ультру»)
local Meshes, MeshCk, FwdX, FwdY, FwdZ, Stats = M.Meshes, M.MeshCk, M.FwdX, M.FwdY, M.FwdZ, M.Stats
local Dyn, BuiltAt = M.Dyn, M.BuiltAt
local EyeX, EyeY, EyeZ = M.EyeX, M.EyeY, M.EyeZ

local DRAW_MIN   = 0.02
local REORIENT   = 0.94      -- cos(20°)
local SHIFT      = 0.18      -- отступ спрайта от закрытой грани, доля вокселя
local WALL_ALPHA = 0.8       -- множитель альфы за каждую закрытую грань
-- Срез спрайта о пол/стену: квад, развёрнутый к камере, протыкает геометрию, и непрозрачная часть
-- текстуры даёт прямую линию. Видимая часть клуба — ~VIS_CORE от полуразмера; спрайт ужимается так,
-- чтобы она не доходила до ближайшей закрытой плоскости (своя грань или грань соседа, до 1.5 вокселя).
local VIS_CORE   = 0.7       -- видимая часть клуба атласа 4×4 (до ~0.42 ячейки от центра)
local MIN_SCALE  = 0.35
local BIG        = 1e9

-- Плоскость закрытой грани вдоль оси от ячейки key: своя грань / грань соседа (на вокселе дальше).
-- bit — бит FACE_BLOCK оси, stride — шаг ключа по оси. Возвращает координату плоскости или ±BIG.
local function UpperPlane(f, key, bit, stride, hi, s)
    if f and band(f, bit) ~= 0 then return hi end
    local f2 = Collision[key + stride]
    if f2 and band(f2, bit) ~= 0 then return hi + s end
    return BIG
end

local function LowerPlane(key, bit, stride, lo, s)
    local f1 = Collision[key - stride]
    if f1 and band(f1, bit) ~= 0 then return lo end
    local f2 = Collision[key - 2 * stride]
    if f2 and band(f2, bit) ~= 0 then return lo - s end
    return -BIG
end
local INVISIBLE  = 0.005     -- газы прозрачнее (водород, зарин…) не рисуются вовсе
-- Спрайты у самой камеры гаснут: изнутри облака видимость задаёт туман движка, а не квад во весь экран.
local NEAR0, NEAR1 = 0.45, 2.2   -- в долях вокселя: ближе NEAR0 — прозрачен, дальше NEAR1 — полностью
local MOVE_REBUILD = 0.5         -- ближний чанк пересобирается, если камера сдвинулась на полвокселя

-- Повороты спрайта: 32 угла (почти непрерывно — узор клубов не повторяется)
local NROT = 32
local COS, SIN = {}, {}
for i = 0, NROT - 1 do
    COS[i] = math.cos(i * 2 * math.pi / NROT + 0.3)
    SIN[i] = math.sin(i * 2 * math.pi / NROT + 0.3)
end

-- Цвет газа по id (кэш, обновляется при регистрации)
local ColR, ColG, ColB = {}, {}, {}
local function CacheColors()
    for id, def in pairs(AetherGas.GasById) do
        ColR[id], ColG[id], ColB[id] = def.color.r, def.color.g, def.color.b
    end
end
CacheColors()
hook.Add("AetherGas.GasRegistered", "AetherGas.Mesher", CacheColors)

local V = Vector(0, 0, 0)          -- переиспользуемая вершина
local LightPos = Vector(0, 0, 0)
-- Освещение по 8 углам чанка (общие углы у соседей → нет ступенек на стыках чанков), трилинейно на спрайт.
-- Угол внутри стены/пола даёт чёрный цвет — такой заменяется средним по остальным.
local LR, LG, LB, LOK = {}, {}, {}, {}
local DR, DG, DB = {}, {}, {}     -- динамический свет в углах (ComputeDynamicLighting)
local DynNormal = Vector(0, 0, 1)  -- нормаль замера: к камере (освещённая сторона облака)

--- Освещение 8 углов чанка. Возвращает true, если в чанке есть заметный динамический свет.
local function SampleCorners(ox, oy, oz, s, fx, fy, fz)
    DynNormal:SetUnpacked(-fx, -fy, -fz)
    local sr, sg, sb, n = 0, 0, 0, 0
    local dynMax = 0
    for c = 0, 7 do
        LightPos:SetUnpacked(ox + band(c, 1) * 8 * s, oy + band(rshift(c, 1), 1) * 8 * s, oz + rshift(c, 2) * 8 * s)
        local lc = render.GetLightColor(LightPos)
        local ok = lc.x + lc.y + lc.z > 0.003
        LOK[c] = ok
        LR[c], LG[c], LB[c] = lc.x, lc.y, lc.z
        if ok then sr, sg, sb, n = sr + lc.x, sg + lc.y, sb + lc.z, n + 1 end
        local dl = render.ComputeDynamicLighting(LightPos, DynNormal)
        DR[c], DG[c], DB[c] = dl.x, dl.y, dl.z
        local m = dl.x > dl.y and dl.x or dl.y
        if dl.z > m then m = dl.z end
        if m > dynMax then dynMax = m end
    end
    if n == 0 then   -- весь чанк «в стене» по углам: берём центр
        LightPos:SetUnpacked(ox + s * 4, oy + s * 4, oz + s * 4)
        local lc = render.GetLightColor(LightPos)
        sr, sg, sb, n = lc.x, lc.y, lc.z, 1
    end
    for c = 0, 7 do
        if not LOK[c] then LR[c], LG[c], LB[c] = sr / n, sg / n, sb / n end
        LR[c] = min(1, LR[c] * 1.5 + 0.42)
        LG[c] = min(1, LG[c] * 1.5 + 0.42)
        LB[c] = min(1, LB[c] * 1.5 + 0.42)
    end
    return dynMax > DYN_MIN
end

-- Трилинейная интерполяция угловых значений arr в точке (u, v, w) ∈ [0, 1]³
local function Tri(arr, u, v, w)
    local a = arr[0] + (arr[1] - arr[0]) * u
    local b = arr[2] + (arr[3] - arr[2]) * u
    local c = arr[4] + (arr[5] - arr[4]) * u
    local d = arr[6] + (arr[7] - arr[6]) * u
    local e = a + (b - a) * v
    local f = c + (d - c) * v
    return e + (f - e) * w
end

--- Свет в точке чанка (tu, tv, tw ∈ [0, 1]): освещение карты + цветной динамический свет.
local function LightAt(tu, tv, tw, dyn)
    local lr, lg, lb = Tri(LR, tu, tv, tw), Tri(LG, tu, tv, tw), Tri(LB, tu, tv, tw)
    if dyn then   -- цветной динамический свет не затеняется газом сверху (источник обычно внутри)
        lr = lr + Tri(DR, tu, tv, tw) * DYN_GAIN
        lg = lg + Tri(DG, tu, tv, tw) * DYN_GAIN
        lb = lb + Tri(DB, tu, tv, tw) * DYN_GAIN
    end
    return lr, lg, lb
end

--- Запомнить ориентацию и позицию камеры при сборке, время и наличие динамического света.
local function MarkBuilt(slot, fx, fy, fz, ex, ey, ez, dyn)
    FwdX[slot], FwdY[slot], FwdZ[slot] = fx, fy, fz
    EyeX[slot], EyeY[slot], EyeZ[slot] = ex, ey, ez
    BuiltAt[slot] = RealTime()
    Dyn[slot] = dyn
end

local function DestroyMesh(slot)
    local m = Meshes[slot]
    if m then m:Destroy() end
    Meshes[slot], MeshCk[slot] = nil, nil
end

-- Мягкое касание поверхностей: прозрачность угла клуба падает до нуля по мере приближения к стенам и потолку
-- (FADE_D) и к полу (FLOOR_FADE — короче: только спрятать линию пересечения; иначе низ облака пустеет и
-- оно «висит» над землёй). Плоскости задаются на ячейку (без аллокаций — upvalue).
local FADE_D, FLOOR_FADE = 0.35, 0.12          -- доли вокселя
local PFloor, PCeil, PLoX, PHiX, PLoY, PHiY, PInv, PInvF = -1e9, 1e9, -1e9, 1e9, -1e9, 1e9, 1, 1
local function SurfFade(x, y, z)
    local d = PCeil - z
    local t = x - PLoX if t < d then d = t end
    t = PHiX - x if t < d then d = t end
    t = y - PLoY if t < d then d = t end
    t = PHiY - y if t < d then d = t end
    d = d * PInv
    t = (z - PFloor) * PInvF
    if t < d then d = t end
    return d <= 0 and 0 or d < 1 and d or 1
end
-- Сеттеры плоскостей: Build меняет их через функции — меньше upvalue у Build (лимит LuaJIT — 60).
local function SetFadeScale(s) PInv, PInvF = 1 / (s * FADE_D), 1 / (s * FLOOR_FADE) end
local function SetPlanes(fl, ce, lx, hx, ly, hy) PFloor, PCeil, PLoX, PHiX, PLoY, PHiY = fl, ce, lx, hx, ly, hy end
local function SetFloor(fl) PFloor = fl end

local function EmitVertex(x, y, z, r, g, b, a, u, v)
    V:SetUnpacked(x, y, z)
    mesh.Position(V)
    mesh.Color(r < 0 and 0 or r < 255 and r or 255, g < 0 and 0 or g < 255 and g or 255,
        b < 0 and 0 or b < 255 and b or 255, a * SurfFade(x, y, z))
    mesh.TexCoord(0, u, v)
    mesh.AdvanceVertex()
end

-- Высота земли под ячейкой: сетка столкновений знает только грани вокселей, а холмы, склоны и дисплейсменты
-- проходят между ними. Трасса вниз по миру (MASK_SOLID_BRUSHONLY — мир статичен) один раз на ячейку, кэш
-- навсегда (сбрасывается со сменой сетки). Трасса без аллокаций: свой входной и выходной стол.
M.Ground = M.Ground or {}
local Ground = M.Ground
local GroundTr, GroundOut = { start = Vector(0, 0, 0), endpos = Vector(0, 0, 0), mask = MASK_SOLID_BRUSHONLY }, {}
GroundTr.output = GroundOut
local function GroundZ(key, x, y, cz0, s)
    local gz = Ground[key]
    if gz == nil then
        GroundTr.start:SetUnpacked(x, y, cz0 + s * 0.6)
        GroundTr.endpos:SetUnpacked(x, y, cz0 - s * 1.5)
        util.TraceLine(GroundTr)
        gz = (GroundOut.Hit and not GroundOut.StartSolid) and GroundOut.HitPos.z or false
        Ground[key] = gz
    end
    return gz
end

-- Подсетка рендера: каждая ячейка — SUB клубов в узлах подсетки 2×2×2 (тетраэдр: 4 из 8 узлов) со случайным
-- дрожанием. Плотность в узле — по градиенту концентрации к соседям (линейная интерполяция поля), поэтому у края
-- облака клубы мельче и прозрачнее: край плавный и скруглённый, а не «кубы». Визуально — вдвое мельче воксель
-- без удорожания симуляции. Вся группа клубов ячейки ещё и сдвинута случайно — сетка сверху не читается.
local SUB, SUB_SIZE = 4, 0.62
local SUBOFF = { -1, -1, -1,  1, 1, -1,  1, -1, 1,  -1, 1, 1 }   -- узлы тетраэдра (×0.25 вокселя)
-- Затенение внутренних ячеек: доля заполненных газом соседей (6 граней) затемняет ячейку — край облака светлее
local AO_K = 0.32
-- Светлый блик: освещённые (верхние) углы клуба уходят к цвету света — густой красный дым сверху розовый
local WHITEN = 1.7
-- Тяжёлые газы (хлор, CO2…) у земли лежат одеялом: клуб сплющен по вертикали (доля высоты)
local HEAVY, FLAT = 1.15, 0.6
local Pdens = P.Density

-- Жар: горячий газ (дым пожара у очага, ~300 °C) светлее и серее — сажа ещё не сгустилась, чернеет он остывая;
-- а над самым огнём подсвечен изнутри оранжевым (пламя под ним). Температура ячейки — поле солвера Temp (°C).
local Temp = Spatial.Temp
local function HeatColor(idx, r, g, b)
    local t = Temp[idx]
    if t < 60 then return r, g, b, 1 end
    local heat = (t - 60) / 260
    if heat > 1 then heat = 1 end
    local k = 0.55 * heat
    r, g, b = r + (128 - r) * k, g + (122 - g) * k, b + (114 - b) * k
    local glow = (t - 170) / 320
    if glow > 0 then
        if glow > 1 then glow = 1 end
        r, g, b = r + 230 * 0.6 * glow, g + 110 * 0.6 * glow, b + 35 * 0.6 * glow
    end
    return r, g, b, 1 - 0.2 * heat
end

-- Течение клубов («Ультра»): скорость газа в ячейке (поля солвера VelX/Y/Z; горячий газ ещё и всплывает)
-- кодируется в целую часть UV — вершинный шейдер ведёт по ней клубы (aether_smoke_vs20.hlsl, там же формат).
-- Атлас занимает дробную часть 0..1, поэтому сдвиг кратен 4. Обычный материал кодов не понимает: меш с кодами
-- собирается только под «Ультру», при её переключении чанки пересобираются (CodeFlow, M.Coded).
local FLOW_Q = 12                  -- юнит/с на шаг кода; диапазон ±8 шагов (±96 юнит/с)
local CodeFlow = false
local VelX, VelY, VelZ = Spatial.VelX, Spatial.VelY, Spatial.VelZ
local function FlowQ(v)
    local i = math.floor(v / FLOW_Q + 8.5)
    return i < 0 and 0 or i > 15 and 15 or i
end
--- Сдвиг UV (du, dv) клуба ячейки idx с фазой ph (0..3).
local function FlowCode(idx, ph)
    if not CodeFlow then return 0, 0 end
    local vz = VelZ[idx]
    local t = Temp[idx]
    if t > 60 then vz = vz + min(60, (t - 60) * 0.3) end   -- жар: дым над огнём заметно поднимается
    return (1 + FlowQ(VelX[idx]) + 16 * FlowQ(VelY[idx])) * 4, (1 + FlowQ(vz) + 16 * ph) * 4
end
local function SetCodeFlow(on) CodeFlow = on end

--- Концентрация соседа: внутри чанка — по индексу, за его границей — через ключ сетки.
local function NeighborConc(inside, idx, key)
    if inside then return Conc[idx] end
    local ni = Solver.KeyIndex(key, false)
    return ni and Conc[ni] or 0
end

local function Build(slot, fx, fy, fz, rx, ry, rz, ux, uy, uz, ex, ey, ez)
    local ck = slotKey[slot]
    local base = (slot - 1) * 512
    local n = 0
    for i = base + 1, base + 512 do
        if Conc[i] > DRAW_MIN and Popac[Gas[i]] > INVISIBLE then n = n + 1 end
    end
    DestroyMesh(slot)
    slotDirty[slot] = false
    MarkBuilt(slot, fx, fy, fz, ex, ey, ez, false)
    if n == 0 then return end

    local s = Spatial.VoxelSize
    local near0, nearInv = s * NEAR0, 1 / (s * (NEAR1 - NEAR0))
    local ox, oy, oz = Spatial.ChunkOrigin(ck)
    local hasDyn = SampleCorners(ox, oy, oz, s, fx, fy, fz)
    MarkBuilt(slot, fx, fy, fz, ex, ey, ez, hasDyn)

    -- ключ локальной (0,0,0): gx = cx·8 и т. д.
    local keyBase = (band(ck, 127) * 8) + (band(rshift(ck, 7), 127) * 8) * 1024 + (band(rshift(ck, 14), 127) * 8) * 1048576

    -- от дальних к ближним по каждой оси
    local x0, x1, xs = 0, 7, 1
    if fx > 0 then x0, x1, xs = 7, 0, -1 end
    local y0, y1, ys = 0, 7, 1
    if fy > 0 then y0, y1, ys = 7, 0, -1 end
    local z0, z1, zs = 0, 7, 1
    if fz > 0 then z0, z1, zs = 7, 0, -1 end

    -- дальний чанк (центр дальше LOD_FAR) — меньше клубов на ячейку
    local LOD_FAR = 2400
    local cdx, cdy, cdz = ox + s * 4 - ex, oy + s * 4 - ey, oz + s * 4 - ez
    local farChunk = cdx * cdx + cdy * cdy + cdz * cdz > LOD_FAR * LOD_FAR

    local m = Mesh(MAT)
    SetFadeScale(s)
    mesh.Begin(m, MATERIAL_QUADS, n * (SUB + 1))   -- + стелющийся клуб у пола (или вырожденный квад)
    for lz = z0, z1, zs do
        for ly = y0, y1, ys do
            for lx = x0, x1, xs do
                local idx = base + lx + ly * 8 + lz * 64 + 1
                local c = Conc[idx]
                local g = Gas[idx]
                if c > DRAW_MIN and Popac[g] > INVISIBLE then
                    local key = keyBase + lx + ly * 1024 + lz * 1048576
                    local cc = c < 1 and c or 1
                    local cx0, cy0, cz0 = ox + lx * s, oy + ly * s, oz + lz * s
                    -- случайный сдвиг всей группы клубов ячейки (как блоки со случайным смещением)
                    local bx = cx0 + (0.5 + ((key * 37) % 61 / 61 - 0.5) * 0.36) * s
                    local by = cy0 + (0.5 + ((key * 41) % 59 / 59 - 0.5) * 0.36) * s
                    local bz = cz0 + (0.5 + ((key * 43) % 53 / 53 - 0.5) * 0.2) * s

                    -- мягкий фейд у геометрии: свои грани (+X/+Y/+Z) и грани соседей (−X/−Y/−Z)
                    local fade = 1
                    local f = Collision[key]
                    if f then
                        if band(f, FACE_BLOCK_X) ~= 0 then bx = bx - s * SHIFT; fade = fade * WALL_ALPHA end
                        if band(f, FACE_BLOCK_X * 2) ~= 0 then by = by - s * SHIFT; fade = fade * WALL_ALPHA end
                        if band(f, FACE_BLOCK_X * 4) ~= 0 then bz = bz - s * SHIFT end
                    end
                    local fnx, fny = Collision[key - 1], Collision[key - 1024]
                    if fnx and band(fnx, FACE_BLOCK_X) ~= 0 then bx = bx + s * SHIFT; fade = fade * WALL_ALPHA end
                    if fny and band(fny, FACE_BLOCK_X * 2) ~= 0 then by = by + s * SHIFT; fade = fade * WALL_ALPHA end

                    -- у камеры клубы гаснут (линейно от NEAR0 до NEAR1 вокселя)
                    local ddx, ddy, ddz = bx - ex, by - ey, bz - ez
                    local near = (sqrt(ddx * ddx + ddy * ddy + ddz * ddz) - near0) * nearInv
                    if near < 1 then fade = fade * (near > 0 and near or 0) end

                    -- соседи по 6 граням: градиент поля (подсетка), затенение изнутри, самозатенение сверху
                    local cxm = NeighborConc(lx > 0, idx - 1, key - 1)
                    local cxp = NeighborConc(lx < 7, idx + 1, key + 1)
                    local cym = NeighborConc(ly > 0, idx - 8, key - 1024)
                    local cyp = NeighborConc(ly < 7, idx + 8, key + 1024)
                    local czm = NeighborConc(lz > 0, idx - 64, key - 1048576)
                    local above = NeighborConc(lz < 7, idx + 64, key + 1048576)
                    local above2 = NeighborConc(lz < 6, idx + 128, key + 2 * 1048576)
                    local occ = (above + above2 * 0.6) * Popac[g]
                    local shade = 1 - SELF_SHADOW * (occ < 1 and occ or 1)
                    local nb = (cxm + cxp + cym + cyp + czm + above) * 2 / 6
                    shade = shade * (1 - AO_K * (nb < 1 and nb or 1))
                    -- градиент на долю вокселя (узлы подсетки — ±0.25 вокселя от центра)
                    local gx, gy, gzz = (cxp - cxm) * 0.5, (cyp - cym) * 0.5, (above - czm) * 0.5

                    local tu, tv, tw = (lx + 0.5) * 0.125, (ly + 0.5) * 0.125, (lz + 0.5) * 0.125
                    local lr, lgg, lb = LightAt(tu, tv, tw, hasDyn)
                    local r = (ColR[g] or 200) * lr * shade
                    local gg = (ColG[g] or 200) * lgg * shade
                    local b = (ColB[g] or 200) * lb * shade
                    -- цвет блика: свет без окраски газом
                    local hr, hg, hb = 255 * (lr < 1 and lr or 1), 255 * (lgg < 1 and lgg or 1), 255 * (lb < 1 and lb or 1)
                    local heatA
                    r, gg, b, heatA = HeatColor(idx, r, gg, b)
                    fade = fade * heatA

                    -- Плоскости, о которые клубы не должны протыкаться (своя/соседняя закрытая грань)
                    local hiX = UpperPlane(f, key, FACE_BLOCK_X, 1, cx0 + s, s)
                    local hiY = UpperPlane(f, key, FACE_BLOCK_X * 2, 1024, cy0 + s, s)
                    local hiZ = UpperPlane(f, key, FACE_BLOCK_X * 4, 1048576, cz0 + s, s)
                    local loX = LowerPlane(key, FACE_BLOCK_X, 1, cx0, s)
                    local loY = LowerPlane(key, FACE_BLOCK_X * 2, 1024, cy0, s)
                    local loZ = LowerPlane(key, FACE_BLOCK_X * 4, 1048576, cz0, s)
                    -- пол: закрытая грань или настоящая земля под ячейкой (склон, дисплейсмент), что выше
                    local gz = GroundZ(key, bx, by, cz0, s)
                    if gz and gz > loZ then loZ = gz end
                    SetPlanes(loZ, hiZ, loX, hiX, loY, hiY)
                    local gh = bz - loZ                                   -- высота центра над полом
                    local flat = (Pdens[g] > HEAVY and gh < s * 1.6) and FLAT or 1
                    -- LOD: ячейка внутри облака (газ со всех сторон) или дальний чанк — 2 крупных клуба вместо SUB:
                    -- внутренность всё равно не видна сквозь край, а перерисовки полупрозрачного вдвое меньше
                    local nsub = (farChunk or nb >= 0.95) and 2 or SUB
                    local lodK = nsub < SUB and 1.3 or 1                  -- клубы крупнее, чтобы закрыть ячейку
                    local aExp = nsub < SUB and 0.75 or 0.5               -- 2 клуба делят плотность на двоих

                    for j = 0, SUB - 1 do
                      if j >= nsub then
                        for _ = 1, 4 do EmitVertex(bx, by, bz, 0, 0, 0, 0, 0, 0) end   -- вырожденный (LOD)
                      else
                        -- узел подсетки + дрожание: детерминированно от (ключ, j) — узор не мерцает при пересборке
                        local o3 = j * 3
                        local h1, h2, h3 = (key * 3 + j * 131) % 97, (key * 5 + j * 71) % 89, (key * 7 + j * 53) % 83
                        local nx = SUBOFF[o3 + 1] * 0.25 + (h1 / 97 - 0.5) * 0.24
                        local ny = SUBOFF[o3 + 2] * 0.25 + (h2 / 89 - 0.5) * 0.24
                        local nz = SUBOFF[o3 + 3] * 0.25 + (h3 / 83 - 0.5) * 0.2
                        local cs = c + gx * nx + gy * ny + gzz * nz      -- плотность в узле (линейно по полю)
                        if cs > 1 then cs = 1 end
                        local x, y, z = bx + nx * s, by + ny * s, bz + nz * s
                        local As = cs > DRAW_MIN and min(1, cs * Popac[g] * DENSITY_GAIN) * fade or 0
                        local a = 255 * (1 - (1 - As) ^ aExp)              -- клубы вместе дают плотность ячейки
                        local half = s * SUB_SIZE * lodK * (0.75 + 0.7 * (cs > 0 and cs or 0)) * (0.7 + ((key + j * 17) % 31) / 31 * 0.65)
                        local rot = (key * 13 + j * 11) % NROT
                        local cr, sr = COS[rot], SIN[rot]
                        local Rx, Ry, Rz = (cr * rx + sr * ux) * half, (cr * ry + sr * uy) * half, (cr * rz + sr * uz) * half * flat
                        local Ux, Uy, Uz = (cr * ux - sr * rx) * half, (cr * uy - sr * ry) * half, (cr * uz - sr * rz) * half * flat

                        -- Не протыкать пол/потолок/стены: протяжённость квада по оси (|R|+|U|) × VIS_CORE не
                        -- длиннее расстояния до ближайшей закрытой плоскости; иначе квад ужимается целиком.
                        if loZ > -BIG and z < loZ + s * 0.12 then z = loZ + s * 0.12 end   -- почти на полу, не в нём
                        local k = 1
                        local e = (abs(Rx) + abs(Ux)) * VIS_CORE
                        local cl = min(x - loX, hiX - x)
                        if e > cl then k = min(k, cl / e) end
                        e = (abs(Ry) + abs(Uy)) * VIS_CORE
                        cl = min(y - loY, hiY - y)
                        if e > cl then k = min(k, cl / e) end
                        e = (abs(Rz) + abs(Uz)) * VIS_CORE
                        cl = hiZ - z
                        if e > cl then k = min(k, cl / e) end
                        if k < 1 then
                            if k < MIN_SCALE then k = MIN_SCALE end
                            Rx, Ry, Rz, Ux, Uy, Uz = Rx * k, Ry * k, Rz * k, Ux * k, Uy * k, Uz * k
                        end
                        -- Верхний слой облака (над ячейкой пусто): видимая часть клуба не выше ячейки + четверть
                        -- вокселя — облако на экране совпадает с газом в сетке (замер урона по телу — sv_network).
                        if above <= DRAW_MIN then
                            local ezz = (abs(Rz) + abs(Uz)) * VIS_CORE
                            local top = cz0 + s * 1.25
                            if z + ezz > top then
                                z = top - ezz
                                if z < cz0 + s * 0.12 then z = cz0 + s * 0.12 end
                            end
                        end

                        -- ячейка атласа 4×4 (другой множитель, чем у поворота — нет корреляции)
                        -- + код течения в целой части UV (фазы клубов ячейки — через четверть, у LOD — через половину)
                        local q = (key * 7 + j * 5) % 16
                        local du, dv = FlowCode(idx, nsub < SUB and j * 2 or j)
                        local u0, v0 = (q % 4) * 0.25 + du, math.floor(q / 4) * 0.25 + dv
                        local u1, v1 = u0 + 0.25, v0 + 0.25
                        -- объём: яркость угла по высоте в мире; освещённые углы уходят к цвету света (блик)
                        -- нормировка по полуразмеру, а не по вертикальному размаху: сбоку — полный объём, сверху
                        -- (клуб лежит в плоскости экрана ≈ горизонтально) — ровное покрывало, а не «пупырчатая плёнка»
                        local kz = TOP_LIGHT / (half * 1.41)
                        local t0, t1 = (-Rz - Uz) * kz, (Rz - Uz) * kz
                        local t2, t3 = (Rz + Uz) * kz, (-Rz + Uz) * kz
                        local w0, w1 = (t0 > 0 and t0 or 0) * WHITEN, (t1 > 0 and t1 or 0) * WHITEN
                        local w2, w3 = (t2 > 0 and t2 or 0) * WHITEN, (t3 > 0 and t3 or 0) * WHITEN
                        t0, t1, t2, t3 = 1 + t0, 1 + t1, 1 + t2, 1 + t3
                        EmitVertex(x - Rx - Ux, y - Ry - Uy, z - Rz - Uz, r * t0 + (hr - r) * w0, gg * t0 + (hg - gg) * w0,
                            b * t0 + (hb - b) * w0, a, u0, v1)
                        EmitVertex(x + Rx - Ux, y + Ry - Uy, z + Rz - Uz, r * t1 + (hr - r) * w1, gg * t1 + (hg - gg) * w1,
                            b * t1 + (hb - b) * w1, a, u1, v1)
                        EmitVertex(x + Rx + Ux, y + Ry + Uy, z + Rz + Uz, r * t2 + (hr - r) * w2, gg * t2 + (hg - gg) * w2,
                            b * t2 + (hb - b) * w2, a, u1, v0)
                        EmitVertex(x - Rx + Ux, y - Ry + Uy, z - Rz + Uz, r * t3 + (hr - r) * w3, gg * t3 + (hg - gg) * w3,
                            b * t3 + (hb - b) * w3, a, u0, v0)
                      end
                    end

                    -- Газ лежит на поверхности: у пола (центр ячейки ниже вокселя над ним) — плотный горизонтальный
                    -- клуб вплотную к земле: облако стелется и касается пола без зазора; клуб параллелен полу —
                    -- линии пересечения нет. Иначе — вырожденный квад (счёт в mesh.Begin).
                    if gz and gz >= loZ - 1 and gh < s * 1.0 then
                        local half = s * (0.8 + 0.4 * cc)
                        local rot = (key * 29) % NROT
                        local cr, sr = COS[rot] * half, SIN[rot] * half
                        local zf = gz + s * 0.04
                        local ga = 255 * min(1, cc * Popac[g] * DENSITY_GAIN * 1.15) * fade * 0.9
                        local q = (key * 11) % 16
                        local u0, v0 = (q % 4) * 0.25, math.floor(q / 4) * 0.25
                        SetFloor(loZ - s)      -- для этого клуба пол не гасит альфу (он над полом), стены — да
                        local dr, dg, db = r * 0.85, gg * 0.85, b * 0.85   -- нижняя сторона облака темнее
                        EmitVertex(bx - cr + sr, by - sr - cr, zf, dr, dg, db, ga, u0, v0 + 0.25)
                        EmitVertex(bx + cr + sr, by + sr - cr, zf, dr, dg, db, ga, u0 + 0.25, v0 + 0.25)
                        EmitVertex(bx + cr - sr, by + sr + cr, zf, dr, dg, db, ga, u0 + 0.25, v0)
                        EmitVertex(bx - cr - sr, by - sr + cr, zf, dr, dg, db, ga, u0, v0)
                    else
                        for _ = 1, 4 do EmitVertex(bx, by, bz, 0, 0, 0, 0, 0, 0) end
                    end
                end
            end
        end
    end
    mesh.End()
    Meshes[slot], MeshCk[slot] = m, ck
    Stats.built = Stats.built + 1
end

-- Переиспользуемые массивы видимых чанков
local ProbePos, ProbeNormal = Vector(0, 0, 0), Vector(0, 0, 1)
local nextProbe = 0
local VisSlot, VisDist = {}, {}
local BuildSlot, BuildDist = {}, {}

local function SortByDist(slots, dists, n, descending)
    -- вставками: видимых чанков десятки, без аллокаций и замыканий
    for i = 2, n do
        local s, d = slots[i], dists[i]
        local j = i - 1
        while j >= 1 and ((descending and dists[j] < d) or (not descending and dists[j] > d)) do
            slots[j + 1], dists[j + 1] = slots[j], dists[j]
            j = j - 1
        end
        slots[j + 1], dists[j + 1] = s, d
    end
end

hook.Add("PostDrawTranslucentRenderables", "AetherGas.Mesher.Draw", function(depth, sky, sky3d)
    if depth or sky or sky3d or not cvDraw:GetBool() then return end
    local hw = Pool.highWater
    if hw == 0 then return end

    local eye = EyePos()
    local ang = EyeAngles()
    local fwd, right, up = ang:Forward(), ang:Right(), ang:Up()
    local ex, ey, ez = eye.x, eye.y, eye.z
    local fx, fy, fz = fwd.x, fwd.y, fwd.z
    local s = Spatial.VoxelSize
    local radius = s * 8 * 0.87
    local maxDist = cvDist:GetFloat() + radius
    local moveSq = (s * MOVE_REBUILD) * (s * MOVE_REBUILD)
    local now = RealTime()
    local probe = now >= nextProbe
    if probe then
        nextProbe = now + DYN_PROBE
        ProbeNormal:SetUnpacked(-fx, -fy, -fz)
    end

    local coded = cvUltra:GetBool() and UltraSupported()
    local Coded = M.Coded
    SetCodeFlow(coded)

    local nVis, nBuild = 0, 0
    for slot = 1, hw do
        local ck = slotKey[slot]
        if ck == -1 then
            if Meshes[slot] then DestroyMesh(slot) end
        else
            if MeshCk[slot] and MeshCk[slot] ~= ck then DestroyMesh(slot) end
            local ox, oy, oz = Spatial.ChunkOrigin(ck)
            local dx, dy, dz = ox + s * 4 - ex, oy + s * 4 - ey, oz + s * 4 - ez
            local dist = sqrt(dx * dx + dy * dy + dz * dz)
            if dist <= maxDist and dx * fx + dy * fy + dz * fz >= -radius then
                local reorient = Meshes[slot] and (FwdX[slot] * fx + FwdY[slot] * fy + FwdZ[slot] * fz) < REORIENT
                if not reorient and Meshes[slot] and dist < radius + s * NEAR1 then
                    -- ближний чанк: затухание у камеры зависит от её позиции
                    local mx, my, mz = ex - (EyeX[slot] or 1e6), ey - (EyeY[slot] or 0), ez - (EyeZ[slot] or 0)
                    reorient = mx * mx + my * my + mz * mz > moveSq
                end
                -- динамический свет мигает и гаснет: такие чанки пересобираются DYN_RATE раз в секунду
                if not reorient and Dyn[slot] and now - (BuiltAt[slot] or 0) > 1 / DYN_RATE then reorient = true end
                -- «Ультра» включили или выключили: коды течения в UV есть только у мешей под неё
                if Meshes[slot] and (Coded[slot] or false) ~= coded then reorient = true end
                -- новый источник света рядом (фаер, огонь): изредка проверяем центр видимого чанка
                if not reorient and not Dyn[slot] and Meshes[slot] and probe then
                    ProbePos:SetUnpacked(ox + s * 4, oy + s * 4, oz + s * 4)
                    local dl = render.ComputeDynamicLighting(ProbePos, ProbeNormal)
                    if dl.x + dl.y + dl.z > DYN_MIN * 3 then reorient = true end
                end
                if slotDirty[slot] or reorient then
                    nBuild = nBuild + 1
                    BuildSlot[nBuild], BuildDist[nBuild] = slot, dist
                end
                nVis = nVis + 1
                VisSlot[nVis], VisDist[nVis] = slot, dist
            end
        end
    end

    -- Пересборка: ближние первыми, в пределах бюджета
    if nBuild > 0 then
        SortByDist(BuildSlot, BuildDist, nBuild, false)
        local t0 = SysTime()
        local deadline = t0 + cvBudget:GetFloat() * 0.001
        local rx, ry, rz, ux, uy, uz = right.x, right.y, right.z, up.x, up.y, up.z
        for i = 1, nBuild do
            Build(BuildSlot[i], fx, fy, fz, rx, ry, rz, ux, uy, uz, ex, ey, ez)
            Coded[BuildSlot[i]] = coded
            if SysTime() > deadline then break end
        end
        Stats.buildMs = (SysTime() - t0) * 1000
    end

    -- Отрисовка от дальних к ближним
    SortByDist(VisSlot, VisDist, nVis, true)
    local mat, ultra = DrawMaterial()
    render.SetMaterial(mat)
    if ultra then UltraBegin() end
    local drawn = 0
    for i = 1, nVis do
        local m = Meshes[VisSlot[i]]
        if m then
            m:Draw()
            drawn = drawn + 1
        end
    end
    if ultra then UltraEnd() end
    Stats.drawn = drawn
end)

--[[
    Камера внутри облака: туман движка (SetupWorldFog/SetupSkyboxFog) вместо заливки экрана.
      • дальность видимости = fogDistance газа / c^0.8 — в густом хлоре видно на ~5 м, по краю облака дальше;
        ближние предметы видны чётко, дальние тонут в цвете газа — как в настоящем облаке;
      • цвет = цвет газа × освещение в точке камеры (в тёмном коридоре туман тёмный, а не светится);
      • плотность, дальность и цвет сглаживаются во времени (нет «щелчка» на границе вокселя);
      • поверх — два полупрозрачных слоя клубов с параллаксом от поворота головы (движение воздуха).
    Спрайты облака у самой камеры гаснут при сборке меша (NEAR0/NEAR1), поэтому экран ими не закрывается.
]]
local fogK, fogEnd, fogR, fogG, fogB, fogMax = 0, 4000, 200, 200, 200, 0.9
local FAR = 12000
local LAYERS = { { 1.1, 0.012, 0 }, { 1.8, -0.02, 0.5 } }   -- масштаб, дрейф, фаза атласа
local Pfog = {}

-- FogDistance — не SoA-поле реестра (нужно только клиенту): кэш по id
local function CacheFog()
    for id, def in pairs(AetherGas.GasById) do
        Pfog[id] = def.fogDistance or 0
    end
end
CacheFog()
hook.Add("AetherGas.GasRegistered", "AetherGas.Mesher.Fog", CacheFog)

hook.Add("Think", "AetherGas.Mesher.Fog", function()
    local dt = FrameTime()
    local targetK, targetEnd = 0, FAR
    if cvDraw:GetBool() and Pool.used > 0 then
        local e = EyePos()
        local key = Spatial.WorldToVoxel(e.x, e.y, e.z)
        local idx = key and Solver.KeyIndex(key, false)
        if idx and Conc[idx] > 0.03 then
            local g, c = Gas[idx], Conc[idx]
            local fd = Pfog[g] or 0
            if fd > 0 then
                local cc = c < 1 and c or 1
                targetK = min(1, cc * 3)
                targetEnd = min(FAR, fd / (cc ^ 0.8))
                -- туман «глухой» только у дымов, перекрывающих обзор; едкие и прозрачные газы — дымка
                fogMax = P.VisionThreshold[g] < 1 and 0.97 or 0.6
                local lc = render.GetLightColor(e)
                local lr, lg, lb = min(1, lc.x * 1.6 + 0.25), min(1, lc.y * 1.6 + 0.25), min(1, lc.z * 1.6 + 0.25)
                local k = min(1, dt * 4)
                fogR = fogR + ((ColR[g] or 200) * lr - fogR) * k
                fogG = fogG + ((ColG[g] or 200) * lg - fogG) * k
                fogB = fogB + ((ColB[g] or 200) * lb - fogB) * k
            end
        end
    end
    fogK = fogK + (targetK - fogK) * min(1, dt * (targetK > fogK and 5 or 2.5))
    -- дальность сглаживается в логарифме: из 12000 в 400 и обратно без рывка
    local le, lt = math.log(fogEnd), math.log(targetK > 0 and targetEnd or FAR)
    fogEnd = math.exp(le + (lt - le) * min(1, dt * 3))
end)

local function ApplyFog(scale)
    if fogK < 0.01 then return end
    render.FogMode(MATERIAL_FOG_LINEAR)
    render.FogStart(0)
    render.FogEnd(fogEnd * scale)
    render.FogMaxDensity(fogMax * fogK)
    render.FogColor(fogR, fogG, fogB)
    return true
end
hook.Add("SetupWorldFog", "AetherGas.Mesher.Fog", function() return ApplyFog(1) end)
hook.Add("SetupSkyboxFog", "AetherGas.Mesher.Fog", function(scale) return ApplyFog(scale) end)

hook.Add("HUDPaintBackground", "AetherGas.Mesher.InCloud", function()
    if fogK < 0.02 or not cvDraw:GetBool() then return end
    local w, h = ScrW(), ScrH()
    local ang = EyeAngles()
    local t = RealTime()
    surface.SetMaterial(MAT)
    surface.SetDrawColor(fogR, fogG, fogB, 38 * fogK)
    for i = 1, #LAYERS do
        local L = LAYERS[i]
        local size = w * L[1]
        -- поворот на 90° сдвигает слой на его ширину × коэффициент параллакса
        local ox = ((ang.y / 90) * size * 0.5 + t * L[2] * w) % size
        local oy = (ang.p / 90) * h * 0.5 * L[1]
        local u0 = L[3]
        for tx = -1, math.ceil(w / size) do
            surface.DrawTexturedRectUV(tx * size + ox - size * 0.25, oy - size * 0.3, size, size, u0, 0, u0 + 0.5, 0.5)
        end
    end
end)

hook.Add("AetherGas.GridRebuilt", "AetherGas.Mesher", function()
    for slot in pairs(Meshes) do DestroyMesh(slot) end
    table.Empty(Ground)   -- ключи ячеек другого размера вокселя
end)
