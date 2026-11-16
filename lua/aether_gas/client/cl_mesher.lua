-- lua/aether_gas/client/cl_mesher.lua
--[[
    Рендер газа: один кэшированный IMesh на слот пула (чанк 8³).

    Каждая непустая ячейка — мягкий квад, развёрнутый к камере на момент сборки:
      • размер 1.5–2.4 вокселя: соседние спрайты перекрываются, «кубичность» сетки исчезает;
      • детерминированный сдвиг и поворот от ключа ячейки (key % 97/89/83, 8 углов) — без повторов узора;
      • у закрытых граней центр отодвигается от стены, альфа падает — нет резкого среза об геометрию;
      • альфа = min(1, c)·opacity, цвет газа × освещение чанка (render.GetLightColor, один вызов на сборку);
      • внутри чанка квады выдаются от дальних к ближним по знаку взгляда по каждой оси.
    Вершин на чанк не больше 512·4 = 2048 — в десятки раз меньше лимита IMesh (65 535).

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

-- Собственная текстура аддона (tools/make_smoke_vtf.py): атлас 2×2 мягких клубов, UnlitGeneric с
-- $vertexcolor/$vertexalpha. Стоковой particle/smokesprites_* в базовом GMod нет — была «шахматка».
local MAT = Material("aether/smoke_puff")
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
local Meshes, MeshCk, FwdX, FwdY, FwdZ, Stats = M.Meshes, M.MeshCk, M.FwdX, M.FwdY, M.FwdZ, M.Stats
local EyeX, EyeY, EyeZ = M.EyeX, M.EyeY, M.EyeZ

local DRAW_MIN   = 0.02
local REORIENT   = 0.94      -- cos(20°)
local SHIFT      = 0.18      -- отступ спрайта от закрытой грани, доля вокселя
local WALL_ALPHA = 0.8       -- множитель альфы за каждую закрытую грань
-- Срез спрайта о пол/стену: квад, развёрнутый к камере, протыкает геометрию, и непрозрачная часть
-- текстуры даёт прямую линию. Видимая часть клуба — ~VIS_CORE от полуразмера; спрайт ужимается так,
-- чтобы она не доходила до ближайшей закрытой плоскости (своя грань или грань соседа, до 1.5 вокселя).
local VIS_CORE   = 0.62
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

-- Повороты спрайта: 8 углов
local COS, SIN = {}, {}
for i = 0, 7 do
    COS[i] = math.cos(i * math.pi / 4 + 0.3)
    SIN[i] = math.sin(i * math.pi / 4 + 0.3)
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

local function SampleCorners(ox, oy, oz, s)
    local sr, sg, sb, n = 0, 0, 0, 0
    for c = 0, 7 do
        LightPos:SetUnpacked(ox + band(c, 1) * 8 * s, oy + band(rshift(c, 1), 1) * 8 * s, oz + rshift(c, 2) * 8 * s)
        local lc = render.GetLightColor(LightPos)
        local ok = lc.x + lc.y + lc.z > 0.003
        LOK[c] = ok
        LR[c], LG[c], LB[c] = lc.x, lc.y, lc.z
        if ok then sr, sg, sb, n = sr + lc.x, sg + lc.y, sb + lc.z, n + 1 end
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

local function DestroyMesh(slot)
    local m = Meshes[slot]
    if m then m:Destroy() end
    Meshes[slot], MeshCk[slot] = nil, nil
end

local function EmitVertex(x, y, z, r, g, b, a, u, v)
    V:SetUnpacked(x, y, z)
    mesh.Position(V)
    mesh.Color(r, g, b, a)
    mesh.TexCoord(0, u, v)
    mesh.AdvanceVertex()
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
    FwdX[slot], FwdY[slot], FwdZ[slot] = fx, fy, fz
    EyeX[slot], EyeY[slot], EyeZ[slot] = ex, ey, ez
    if n == 0 then return end

    local s = Spatial.VoxelSize
    local near0, nearInv = s * NEAR0, 1 / (s * (NEAR1 - NEAR0))
    local ox, oy, oz = Spatial.ChunkOrigin(ck)
    SampleCorners(ox, oy, oz, s)

    -- ключ локальной (0,0,0): gx = cx·8 и т. д.
    local keyBase = (band(ck, 127) * 8) + (band(rshift(ck, 7), 127) * 8) * 1024 + (band(rshift(ck, 14), 127) * 8) * 1048576

    -- от дальних к ближним по каждой оси
    local x0, x1, xs = 0, 7, 1
    if fx > 0 then x0, x1, xs = 7, 0, -1 end
    local y0, y1, ys = 0, 7, 1
    if fy > 0 then y0, y1, ys = 7, 0, -1 end
    local z0, z1, zs = 0, 7, 1
    if fz > 0 then z0, z1, zs = 7, 0, -1 end

    local m = Mesh(MAT)
    mesh.Begin(m, MATERIAL_QUADS, n)
    for lz = z0, z1, zs do
        for ly = y0, y1, ys do
            for lx = x0, x1, xs do
                local idx = base + lx + ly * 8 + lz * 64 + 1
                local c = Conc[idx]
                local g = Gas[idx]
                if c > DRAW_MIN and Popac[g] > INVISIBLE then
                    local key = keyBase + lx + ly * 1024 + lz * 1048576
                    local cc = c < 1 and c or 1

                    local x = ox + (lx + 0.5) * s + ((key % 97) / 97 - 0.5) * s * 0.35
                    local y = oy + (ly + 0.5) * s + ((key % 89) / 89 - 0.5) * s * 0.35
                    -- По вертикали разброс больше: ряды спрайтов на одной высоте давали полосы у потолка/пола
                    local z = oz + (lz + 0.5) * s + ((key % 83) / 83 - 0.5) * s * 0.9

                    -- мягкий фейд у геометрии: свои грани (+X/+Y/+Z) и грани соседей (−X/−Y/−Z)
                    local fade = 1
                    local f = Collision[key]
                    if f then
                        if band(f, FACE_BLOCK_X) ~= 0 then x = x - s * SHIFT; fade = fade * WALL_ALPHA end
                        if band(f, FACE_BLOCK_X * 2) ~= 0 then y = y - s * SHIFT; fade = fade * WALL_ALPHA end
                        if band(f, FACE_BLOCK_X * 4) ~= 0 then z = z - s * SHIFT; fade = fade * WALL_ALPHA end
                    end
                    local fnx, fny, fnz = Collision[key - 1], Collision[key - 1024], Collision[key - 1048576]
                    if fnx and band(fnx, FACE_BLOCK_X) ~= 0 then x = x + s * SHIFT; fade = fade * WALL_ALPHA end
                    if fny and band(fny, FACE_BLOCK_X * 2) ~= 0 then y = y + s * SHIFT; fade = fade * WALL_ALPHA end
                    if fnz and band(fnz, FACE_BLOCK_X * 4) ~= 0 then z = z + s * SHIFT; fade = fade * WALL_ALPHA end

                    -- у камеры спрайт гаснет (линейно от NEAR0 до NEAR1 вокселя)
                    local ddx, ddy, ddz = x - ex, y - ey, z - ez
                    local near = (sqrt(ddx * ddx + ddy * ddy + ddz * ddz) - near0) * nearInv
                    if near < 1 then fade = fade * (near > 0 and near or 0) end
                    local a = 255 * min(1, cc * Popac[g] * DENSITY_GAIN) * fade
                    local tu, tv, tw = (lx + 0.5) * 0.125, (ly + 0.5) * 0.125, (lz + 0.5) * 0.125
                    local r = (ColR[g] or 200) * Tri(LR, tu, tv, tw)
                    local gg = (ColG[g] or 200) * Tri(LG, tu, tv, tw)
                    local b = (ColB[g] or 200) * Tri(LB, tu, tv, tw)

                    local half = s * (0.85 + 0.5 * cc) * (0.85 + (key % 31) / 31 * 0.4)
                    local rot = key % 8
                    local cr, sr = COS[rot], SIN[rot]
                    local Rx, Ry, Rz = (cr * rx + sr * ux) * half, (cr * ry + sr * uy) * half, (cr * rz + sr * uz) * half
                    local Ux, Uy, Uz = (cr * ux - sr * rx) * half, (cr * uy - sr * ry) * half, (cr * uz - sr * rz) * half

                    -- Не протыкать пол/потолок/стены: протяжённость квада по оси (|R|+|U|) × VIS_CORE не
                    -- длиннее расстояния до ближайшей закрытой плоскости; иначе квад ужимается целиком.
                    local cx0, cy0, cz0 = ox + lx * s, oy + ly * s, oz + lz * s
                    local hiX = UpperPlane(f, key, FACE_BLOCK_X, 1, cx0 + s, s)
                    local hiY = UpperPlane(f, key, FACE_BLOCK_X * 2, 1024, cy0 + s, s)
                    local hiZ = UpperPlane(f, key, FACE_BLOCK_X * 4, 1048576, cz0 + s, s)
                    local loX = LowerPlane(key, FACE_BLOCK_X, 1, cx0, s)
                    local loY = LowerPlane(key, FACE_BLOCK_X * 2, 1024, cy0, s)
                    local loZ = LowerPlane(key, FACE_BLOCK_X * 4, 1048576, cz0, s)
                    if loZ > -BIG and z < loZ + s * 0.3 then z = loZ + s * 0.3 end   -- клуб не лежит в полу
                    local k = 1
                    local e = (abs(Rx) + abs(Ux)) * VIS_CORE
                    local cl = min(x - loX, hiX - x)
                    if e > cl then k = min(k, cl / e) end
                    e = (abs(Ry) + abs(Uy)) * VIS_CORE
                    cl = min(y - loY, hiY - y)
                    if e > cl then k = min(k, cl / e) end
                    e = (abs(Rz) + abs(Uz)) * VIS_CORE
                    cl = min(z - loZ, hiZ - z)
                    if e > cl then k = min(k, cl / e) end
                    if k < 1 then
                        if k < MIN_SCALE then k = MIN_SCALE end
                        Rx, Ry, Rz, Ux, Uy, Uz = Rx * k, Ry * k, Rz * k, Ux * k, Uy * k, Uz * k
                    end

                    -- ячейка атласа 2×2 по ключу (другой множитель, чем у поворота — нет корреляции)
                    local q = (key * 7) % 4
                    local u0, v0 = (q % 2) * 0.5, (q >= 2) and 0.5 or 0
                    local u1, v1 = u0 + 0.5, v0 + 0.5
                    EmitVertex(x - Rx - Ux, y - Ry - Uy, z - Rz - Uz, r, gg, b, a, u0, v1)
                    EmitVertex(x + Rx - Ux, y + Ry - Uy, z + Rz - Uz, r, gg, b, a, u1, v1)
                    EmitVertex(x + Rx + Ux, y + Ry + Uy, z + Rz + Uz, r, gg, b, a, u1, v0)
                    EmitVertex(x - Rx + Ux, y - Ry + Uy, z - Rz + Uz, r, gg, b, a, u0, v0)
                end
            end
        end
    end
    mesh.End()
    Meshes[slot], MeshCk[slot] = m, ck
    Stats.built = Stats.built + 1
end

-- Переиспользуемые массивы видимых чанков
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
            if SysTime() > deadline then break end
        end
        Stats.buildMs = (SysTime() - t0) * 1000
    end

    -- Отрисовка от дальних к ближним
    SortByDist(VisSlot, VisDist, nVis, true)
    render.SetMaterial(MAT)
    local drawn = 0
    for i = 1, nVis do
        local m = Meshes[VisSlot[i]]
        if m then
            m:Draw()
            drawn = drawn + 1
        end
    end
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
end)
