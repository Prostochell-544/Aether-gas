-- lua/aether_gas/shared/sh_spatial.lua
--[[
    Пространственная основа Aether (shared): упаковка координат, пул чанков (SoA), ленивый кэш коллизий.

    1) КЛЮЧ ВОКСЕЛЯ — 30-битное целое, всегда >= 0 в int32 (LuaJIT bit.*):
           bits 29..20 = gz | bits 19..10 = gy | bits 9..0 = gx,      g = floor(world / size) + 512
       Соседи считаются без битовых операций: ±1 по X, ±1024 по Y, ±1048576 по Z.
       Пограничные ячейки (g == 0 или g == 1023) — вечная стена: переход key ± 1 через край ряда
       упирается в неё и не «телепортирует» газ на противоположную сторону карты.

    2) ЧАНК 8×8×8:  chunkKey = (gx>>3) | (gy>>3)<<7 | (gz>>3)<<14     (21 бит)
                    li       = (gx&7)  | (gy&7)<<3  | (gz&7)<<6       (0..511)
       Данные газа — Structure of Arrays в общем пуле: Field[(slot-1)*512 + li + 1].
       Слот выдаётся из стека свободных и обнуляется только при выдаче; массивы не сжимаются,
       поэтому после прогрева пул работает без аллокаций.

    3) КОЛЛИЗИИ ХРАНЯТСЯ ПО ГРАНЯМ, а не по ячейкам. Проверка «центр ячейки в стене?» пропускает
       тонкие стены (8 юнитов при вокселе 40): стена между двумя центрами не задевает ни один из них,
       и газ просачивается в соседнюю комнату. Поэтому каждая ячейка V владеет тремя гранями
       (+X, +Y, +Z) и трассирует отрезок «центр V → центр соседа» тонким TraceHull. Любая
       геометрия между центрами закрывает грань. Грань «−X» ячейки V — это «+X» ячейки V−1.

       Collision[voxelKey] = flags:
         bit  0..2   FACE_KNOWN_X/Y/Z   грань +X/+Y/+Z протрассирована
         bit  3..5   FACE_WORLD_X/Y/Z   грань закрыта статикой BSP или prop_static — навсегда
         bit  6..8   FACE_DYN_X/Y/Z     грань закрыта динамической сущностью (дверь, стекло, проп)
         bit  9      CELL_KNOWN         центр ячейки протрассирован
         bit 10      SOLID_WORLD        центр внутри статики: ячейка мертва навсегда, трейсов граней нет
         bit 11      SOLID_DYNAMIC      центр внутри динамической сущности
         bit 12..14  FACE_SKY_X/Y/Z     грань упирается в skybox (солвер считает её стоком в атмосферу)

       Мировые биты (WORLD/SKY/SOLID_WORLD) не сбрасываются никогда. ClearDynamicBlock стирает только
       динамический слой и признаки «известно» для не-мировых граней; повторный трейс идёт через
       RebakeVoxelCollision. Пока грань не запечена, FaceState возвращает −1 (солвер трактует её как
       закрытую) и ставит владельца в очередь ленивого запекания с бюджетом aether_probe_budget.

    Нулевые аллокации: горячие функции работают с числами и upvalue-векторами (SetUnpacked).
    Единственная неизбежная аллокация — векторы HitPos/HitNormal внутри результата util.TraceHull;
    трейсы же строго дозированы бюджетами очередей и в цикл солвера не попадают.
]]

local AetherGas = AetherGas
local Spatial   = AetherGas.Spatial
local Portals   = AetherGas.Portals
local C         = AetherGas.Const
local CV        = AetherGas.CVar

local band, bor, bnot, lshift, rshift = bit.band, bit.bor, bit.bnot, bit.lshift, bit.rshift
local floor, min = math.floor, math.min
local IsValid    = IsValid
local SysTime    = SysTime
local TraceHull  = util.TraceHull

---------------------------------------------------------------------------------------------------
-- 1. Сетка и упаковка координат
---------------------------------------------------------------------------------------------------
local GRID_MASK    = C.GRID_DIM - 1               -- 1023
local GRID_BIAS    = C.GRID_BIAS                  -- 512
local Y_STRIDE     = C.GRID_DIM                   -- 1 << 10
local Z_STRIDE     = C.GRID_DIM * C.GRID_DIM      -- 1 << 20
local MAX_KEY      = Z_STRIDE * C.GRID_DIM - 1    -- (1 << 30) - 1
local CHUNK_VOLUME = C.CHUNK_VOLUME

Spatial.GRID_MASK = GRID_MASK
Spatial.GRID_BIAS = GRID_BIAS
Spatial.Y_STRIDE  = Y_STRIDE
Spatial.Z_STRIDE  = Z_STRIDE
Spatial.MAX_KEY   = MAX_KEY

-- Направления: 0 +X, 1 −X, 2 +Y, 3 −Y, 4 +Z, 5 −Z   (ось = dir >> 1, отрицательное = dir & 1)
Spatial.DIR_STRIDE  = { [0] = 1, -1, Y_STRIDE, -Y_STRIDE, Z_STRIDE, -Z_STRIDE }
Spatial.AXIS_STRIDE = { [0] = 1, Y_STRIDE, Z_STRIDE }
local AXIS_STRIDE = Spatial.AXIS_STRIDE

-- Текущий размер вокселя: upvalue для горячих функций, синхронизируется в Spatial.Rebuild.
local VoxelSize = Spatial.VoxelSize or C.VOXEL_SIZE_MIN
local InvSize   = 1 / VoxelSize

function Spatial.PackKey(gx, gy, gz)
    return bor(gx, lshift(gy, 10), lshift(gz, 20))
end

function Spatial.UnpackKey(key)
    return band(key, GRID_MASK), band(rshift(key, 10), GRID_MASK), band(rshift(key, 20), GRID_MASK)
end

--- Мировые координаты → индексы сетки. Результат может выйти за 0..1023 — проверяет вызывающий.
function Spatial.WorldToGrid(x, y, z)
    return floor(x * InvSize) + GRID_BIAS, floor(y * InvSize) + GRID_BIAS, floor(z * InvSize) + GRID_BIAS
end

--- Мировые координаты → voxelKey (nil, если точка вне сетки).
function Spatial.WorldToVoxel(x, y, z)
    local gx = floor(x * InvSize) + GRID_BIAS
    local gy = floor(y * InvSize) + GRID_BIAS
    local gz = floor(z * InvSize) + GRID_BIAS
    if gx < 0 or gy < 0 or gz < 0 or gx > GRID_MASK or gy > GRID_MASK or gz > GRID_MASK then
        return nil
    end
    return bor(gx, lshift(gy, 10), lshift(gz, 20))
end

local function VoxelCenter(key)
    local s = VoxelSize
    return (band(key, GRID_MASK) - GRID_BIAS + 0.5) * s,
           (band(rshift(key, 10), GRID_MASK) - GRID_BIAS + 0.5) * s,
           (band(rshift(key, 20), GRID_MASK) - GRID_BIAS + 0.5) * s
end
Spatial.VoxelCenter = VoxelCenter

local function IsBorder(key)
    local gx, gy, gz = band(key, GRID_MASK), band(rshift(key, 10), GRID_MASK), band(rshift(key, 20), GRID_MASK)
    return gx == 0 or gy == 0 or gz == 0 or gx == GRID_MASK or gy == GRID_MASK or gz == GRID_MASK
end
Spatial.IsBorder = IsBorder

local function ChunkKeyOf(key)
    return bor(band(rshift(key, 3), 127), lshift(band(rshift(key, 13), 127), 7), lshift(band(rshift(key, 23), 127), 14))
end

--- voxelKey → chunkKey, локальный индекс 0..511.
function Spatial.ChunkOf(key)
    return ChunkKeyOf(key), bor(band(key, 7), lshift(band(rshift(key, 10), 7), 3), lshift(band(rshift(key, 20), 7), 6))
end

--- (chunkKey, li) → voxelKey. Обратная к ChunkOf.
function Spatial.ChunkVoxelKey(chunkKey, li)
    local gx = bor(lshift(band(chunkKey, 127), 3), band(li, 7))
    local gy = bor(lshift(band(rshift(chunkKey, 7), 127), 3), band(rshift(li, 3), 7))
    local gz = bor(lshift(band(rshift(chunkKey, 14), 127), 3), band(rshift(li, 6), 7))
    return bor(gx, lshift(gy, 10), lshift(gz, 20))
end

--- Минимальный угол чанка в мировых координатах: chunk·8 вокселей − 512 → (c − 64)·8·size.
function Spatial.ChunkOrigin(chunkKey)
    local s8 = VoxelSize * 8
    return (band(chunkKey, 127) - 64) * s8, (band(rshift(chunkKey, 7), 127) - 64) * s8, (band(rshift(chunkKey, 14), 127) - 64) * s8
end

---------------------------------------------------------------------------------------------------
-- 2. Кольцевая очередь ключей с дедупликацией
-- Ёмкость — степень двойки, индекс хвоста = (head + count) & (cap − 1). Буфер заполнен нулями заранее,
-- чтобы лежать в массивной части таблицы. Рост (удвоение) — единственная аллокация, и только при
-- переполнении; push/pop работают без выделения памяти.
---------------------------------------------------------------------------------------------------
local function QueueNew(capacity)
    local cap = 16
    while cap < (capacity or 16) do cap = cap * 2 end
    local buf = {}
    for i = 1, cap do buf[i] = 0 end
    return { buf = buf, set = {}, cap = cap, head = 0, count = 0 }
end

local function QueueGrow(q)
    local old, oldCap, head, count = q.buf, q.cap, q.head, q.count
    local newCap = oldCap * 2
    local buf = {}
    for i = 0, count - 1 do buf[i + 1] = old[band(head + i, oldCap - 1) + 1] end
    for i = count + 1, newCap do buf[i] = 0 end
    q.buf, q.cap, q.head = buf, newCap, 0
end

local function QueuePush(q, key)
    if q.set[key] then return false end
    if q.count >= q.cap then QueueGrow(q) end
    q.buf[band(q.head + q.count, q.cap - 1) + 1] = key
    q.count = q.count + 1
    q.set[key] = true
    return true
end

local function QueuePeek(q)
    if q.count == 0 then return nil end
    return q.buf[q.head + 1]
end

local function QueuePop(q)
    if q.count == 0 then return nil end
    local key = q.buf[q.head + 1]
    q.head = band(q.head + 1, q.cap - 1)
    q.count = q.count - 1
    q.set[key] = nil
    return key
end

local function QueueClear(q)
    table.Empty(q.set)
    q.head, q.count = 0, 0
end

Spatial.QueueNew, Spatial.QueuePush, Spatial.QueuePeek = QueueNew, QueuePush, QueuePeek
Spatial.QueuePop, Spatial.QueueClear = QueuePop, QueueClear

Spatial.ProbeQ = Spatial.ProbeQ or QueueNew(4096)
local ProbeQ = Spatial.ProbeQ

---------------------------------------------------------------------------------------------------
-- 3. Пул чанков (Structure of Arrays)
-- Индекс ячейки в любом поле: lshift(slot − 1, 9) + li + 1. Поля объявляются через DeclareField —
-- солвер и рендер добавляют свои (например, буфер следующего шага) без правки этого файла.
---------------------------------------------------------------------------------------------------
local Pool = Spatial.Pool
if not Pool then
    Pool = {
        fields     = {},  -- [name] = flat array
        fieldNames = {},  -- порядок объявления
        defaults   = {},  -- [name] = значение при выдаче слота
        slotKey    = {},  -- [slot] = chunkKey или −1 (свободен)
        slotDirty  = {},  -- [slot] = true → клиентский меш чанка надо пересобрать
        slotCount  = {},  -- [slot] = число непустых ячеек (ведёт солвер)
        chunkSlot  = {},  -- [chunkKey] = slot
        free       = {},  -- стек свободных слотов
        freeTop    = 0,
        highWater  = 0,   -- сколько слотов когда-либо выдавалось (длина массивов / 512)
        used       = 0,
    }
    Spatial.Pool = Pool
end

function Spatial.DeclareField(name, default)
    local arr = Pool.fields[name]
    Pool.defaults[name] = default
    if arr then return arr end
    arr = {}
    for i = 1, Pool.highWater * CHUNK_VOLUME do arr[i] = default end
    Pool.fields[name] = arr
    Pool.fieldNames[#Pool.fieldNames + 1] = name
    return arr
end

-- Базовые поля вокселя
Spatial.Gas  = Spatial.DeclareField("Gas", 0)                -- id газа, 0 = пусто
Spatial.Conc = Spatial.DeclareField("Conc", 0)               -- концентрация 0..1
Spatial.Temp = Spatial.DeclareField("Temp", C.AMBIENT_TEMP)  -- °C
Spatial.VelX = Spatial.DeclareField("VelX", 0)               -- локальный импульс, юнит/с
Spatial.VelY = Spatial.DeclareField("VelY", 0)
Spatial.VelZ = Spatial.DeclareField("VelZ", 0)

function Spatial.SlotBase(slot)
    return lshift(slot - 1, 9)
end

function Spatial.GetSlot(chunkKey)
    return Pool.chunkSlot[chunkKey]
end

--- Выдаёт (или возвращает уже выданный) слот чанку. nil — пул исчерпан (aether_max_chunks).
function Spatial.AcquireChunk(chunkKey)
    local slot = Pool.chunkSlot[chunkKey]
    if slot then return slot end
    if Pool.used >= min(CV.MaxChunks:GetInt(), C.MAX_CHUNKS_HARD) then return nil end

    if Pool.freeTop > 0 then
        slot = Pool.free[Pool.freeTop]
        Pool.freeTop = Pool.freeTop - 1
    else
        slot = Pool.highWater + 1
        Pool.highWater = slot
    end

    local base = lshift(slot - 1, 9)
    local names, fields, defaults = Pool.fieldNames, Pool.fields, Pool.defaults
    for f = 1, #names do
        local name = names[f]
        local arr, def = fields[name], defaults[name]
        for i = base + 1, base + CHUNK_VOLUME do arr[i] = def end
    end

    Pool.slotKey[slot]       = chunkKey
    Pool.chunkSlot[chunkKey] = slot
    Pool.slotDirty[slot]     = true
    Pool.slotCount[slot]     = 0
    Pool.used = Pool.used + 1
    return slot
end

function Spatial.ReleaseChunk(chunkKey)
    local slot = Pool.chunkSlot[chunkKey]
    if not slot then return end
    Pool.chunkSlot[chunkKey] = nil
    Pool.slotKey[slot]   = -1
    Pool.slotDirty[slot] = false
    Pool.slotCount[slot] = 0
    Pool.freeTop = Pool.freeTop + 1
    Pool.free[Pool.freeTop] = slot
    Pool.used = Pool.used - 1
end

local function ResetPool()
    table.Empty(Pool.chunkSlot)
    -- Стек свободных в обратном порядке: первым снова выдаётся слот 1 (плотнее в кэше CPU).
    local top = 0
    for slot = Pool.highWater, 1, -1 do
        Pool.slotKey[slot]   = -1
        Pool.slotDirty[slot] = false
        Pool.slotCount[slot] = 0
        top = top + 1
        Pool.free[top] = slot
    end
    Pool.freeTop, Pool.used = top, 0
end

local function MarkVoxelDirty(key)
    local slot = Pool.chunkSlot[ChunkKeyOf(key)]
    if slot then Pool.slotDirty[slot] = true end
end

function Spatial.MarkChunkDirty(chunkKey)
    local slot = Pool.chunkSlot[chunkKey]
    if slot then Pool.slotDirty[slot] = true end
end

function Spatial.MarkAllDirty()
    for slot = 1, Pool.highWater do
        if Pool.slotKey[slot] ~= -1 then Pool.slotDirty[slot] = true end
    end
end

---------------------------------------------------------------------------------------------------
-- 4. Кэш коллизий: флаги
---------------------------------------------------------------------------------------------------
local FACE_KNOWN_X   = 0x0001   -- Y = 0x0002, Z = 0x0004  (для оси a: lshift(FACE_KNOWN_X, a))
local FACE_WORLD_X   = 0x0008   -- Y = 0x0010, Z = 0x0020
local FACE_DYN_X     = 0x0040   -- Y = 0x0080, Z = 0x0100
local CELL_KNOWN     = 0x0200
local SOLID_WORLD    = 0x0400
local SOLID_DYNAMIC  = 0x0800
local FACE_SKY_X     = 0x1000   -- Y = 0x2000, Z = 0x4000

local FACE_KNOWN_ALL = 0x0007
local FACE_WORLD_ALL = 0x0038
local FACE_DYN_ALL   = 0x01C0
local FACE_SKY_ALL   = 0x7000
local FACE_BLOCK_X   = 0x0048   -- FACE_WORLD_X | FACE_DYN_X
local SOLID_ANY      = 0x0C00   -- SOLID_WORLD | SOLID_DYNAMIC
local FULL_WORLD     = 0x063F   -- CELL_KNOWN | SOLID_WORLD | FACE_KNOWN_ALL | FACE_WORLD_ALL

Spatial.FACE_KNOWN_X, Spatial.FACE_WORLD_X, Spatial.FACE_DYN_X = FACE_KNOWN_X, FACE_WORLD_X, FACE_DYN_X
Spatial.FACE_SKY_X, Spatial.FACE_BLOCK_X = FACE_SKY_X, FACE_BLOCK_X
Spatial.CELL_KNOWN, Spatial.SOLID_WORLD, Spatial.SOLID_DYNAMIC = CELL_KNOWN, SOLID_WORLD, SOLID_DYNAMIC
Spatial.SOLID_ANY, Spatial.FULL_WORLD = SOLID_ANY, FULL_WORLD
Spatial.FACE_KNOWN_ALL, Spatial.FACE_WORLD_ALL = FACE_KNOWN_ALL, FACE_WORLD_ALL
Spatial.FACE_DYN_ALL, Spatial.FACE_SKY_ALL = FACE_DYN_ALL, FACE_SKY_ALL

-- Результаты трейса
local HIT_NONE, HIT_WORLD, HIT_DYNAMIC, HIT_SKY = 0, 1, 2, 3
Spatial.HIT_NONE, Spatial.HIT_WORLD, Spatial.HIT_DYNAMIC, Spatial.HIT_SKY = HIT_NONE, HIT_WORLD, HIT_DYNAMIC, HIT_SKY

Spatial.Collision   = Spatial.Collision or {}
Spatial.CachedCount = Spatial.CachedCount or 0
Spatial.Stats       = Spatial.Stats or { traces = 0, probes = 0, rebakes = 0 }
local Collision = Spatial.Collision   -- таблица никогда не заменяется, только очищается
local Stats     = Spatial.Stats

--- Флаги после сброса динамического слоя: остаются мировые грани (вместе с признаком «известно»),
-- небо и SOLID_WORLD. Чистая функция — используется и для оценки стоимости перепроверки.
local function ClearedFlags(f)
    local worldFaces = band(f, FACE_WORLD_ALL)
    local keep = bor(worldFaces, rshift(worldFaces, 3), band(f, FACE_SKY_ALL))
    if band(f, SOLID_WORLD) ~= 0 then keep = bor(keep, CELL_KNOWN, SOLID_WORLD) end
    return keep
end
Spatial.ClearedFlags = ClearedFlags

-- popcount для трёх бит «грань неизвестна»
local POPCOUNT3 = { [0] = 0, 1, 1, 2, 1, 2, 2, 3 }

--- Верхняя оценка числа трейсов, нужных для дозапекания ячейки с флагами f (f == nil — новая).
-- Если центр ещё не проверен, берём худший случай 4 (центр + 3 грани): бюджет тика не превышается никогда.
local function PendingCost(f)
    if f == nil or band(f, CELL_KNOWN) == 0 then return 4 end
    if band(f, SOLID_ANY) ~= 0 then return 0 end   -- твёрдая ячейка закрывает грани без трейсов
    return POPCOUNT3[band(bnot(f), FACE_KNOWN_ALL)]
end

---------------------------------------------------------------------------------------------------
-- 5. Трассировка
---------------------------------------------------------------------------------------------------
-- «Толстый луч» ±1 юнит: не проскальзывает в микрощели между брашами, но проходит в любой проём.
local TRACE_EXTENT = 1
-- Физпроп с BoundingRadius меньше этой доли вокселя газ не задерживает (банки, гильзы, стулья).
local PROP_BLOCK_RADIUS = 0.75

-- Игроки/NPC (CONTENTS_MONSTER) и невидимые клипы в маску не входят — газ сквозь них проходит.
local MASK_GAS_BASE = bor(CONTENTS_SOLID, CONTENTS_MOVEABLE, CONTENTS_WINDOW)

local IGNORED_COLLISION_GROUP = {
    [COLLISION_GROUP_DEBRIS]             = true,
    [COLLISION_GROUP_DEBRIS_TRIGGER]     = true,
    [COLLISION_GROUP_INTERACTIVE_DEBRIS] = true,
    [COLLISION_GROUP_WEAPON]             = true,
}

--- Фильтр трейсов: true — сущность задерживает газ. Определён один раз (не замыкание на каждый трейс).
local function IsGasBlocker(ent)
    -- worldspawn и статические пропы приходят как невалидная сущность — блокируют всегда.
    if not IsValid(ent) then return true end
    if ent:IsPlayer() or ent:IsNPC() or ent:IsNextBot() or ent:IsWeapon() or ent:IsRagdoll() or ent:IsVehicle() then
        return false
    end
    if Portals.ShatteredSurfaces[ent:EntIndex()] then return false end
    if IGNORED_COLLISION_GROUP[ent:GetCollisionGroup()] then return false end
    if ent:GetMoveType() == MOVETYPE_VPHYSICS and ent:BoundingRadius() < VoxelSize * PROP_BLOCK_RADIUS then
        return false
    end
    return true
end
Spatial.IsGasBlocker = IsGasBlocker

local TrStart = Vector(0, 0, 0)
local TrEnd   = Vector(0, 0, 0)
local TrOut   = {}
local TrIn    = {
    start  = TrStart,
    endpos = TrEnd,
    mins   = Vector(-TRACE_EXTENT, -TRACE_EXTENT, -TRACE_EXTENT),
    maxs   = Vector(TRACE_EXTENT, TRACE_EXTENT, TRACE_EXTENT),
    mask   = MASK_GAS_BASE,
    filter = IsGasBlocker,
    output = TrOut,
}

--- Один трейс от (x0,y0,z0) до (x1,y1,z1). Нулевая длина — проверка «точка внутри твёрдого».
-- Source сначала трассирует мир и при StartSolid в мире до сущностей не доходит, поэтому
-- «мир + дверь в одной точке» классифицируется как мир (что верно: мир не сдвинется никогда).
local function RunTrace(x0, y0, z0, x1, y1, z1)
    TrStart:SetUnpacked(x0, y0, z0)
    TrEnd:SetUnpacked(x1, y1, z1)
    TraceHull(TrIn)
    Stats.traces = Stats.traces + 1

    if not (TrOut.Hit or TrOut.StartSolid) then return HIT_NONE, nil end
    local ent = TrOut.Entity
    if TrOut.HitWorld or not IsValid(ent) then
        if TrOut.HitSky then return HIT_SKY, nil end
        return HIT_WORLD, nil
    end
    return HIT_DYNAMIC, ent
end

--- Диагностика: свежий трейс центра ячейки без записи в кэш.
function Spatial.TraceCell(key)
    local x, y, z = VoxelCenter(key)
    return RunTrace(x, y, z, x, y, z)
end

--- Диагностика: свежий трейс грани (ось 0/1/2 = +X/+Y/+Z) ячейки key без записи в кэш.
function Spatial.TraceFace(key, axis)
    local x, y, z = VoxelCenter(key)
    local s = VoxelSize
    if axis == 0 then return RunTrace(x, y, z, x + s, y, z) end
    if axis == 1 then return RunTrace(x, y, z, x, y + s, z) end
    return RunTrace(x, y, z, x, y, z + s)
end

---------------------------------------------------------------------------------------------------
-- 6. Запекание ячейки
---------------------------------------------------------------------------------------------------
local function CollisionChanged(key, old, new)
    -- Грани ячейки граничат с тремя соседями в плюс; если сосед в другом чанке — пометить и его.
    MarkVoxelDirty(key)
    if band(key, 7) == 7 then MarkVoxelDirty(key + 1) end
    if band(rshift(key, 10), 7) == 7 then MarkVoxelDirty(key + Y_STRIDE) end
    if band(rshift(key, 20), 7) == 7 then MarkVoxelDirty(key + Z_STRIDE) end

    local listener = Spatial.CollisionListener   -- солвер подписывается одной функцией, без hook.Run
    if listener then listener(key, old, new) end
end

--- Дотрассировывает неизвестные части ячейки, начиная с флагов f. old — флаги до операции
-- (nil — ячейки в кэше не было). Возвращает число выполненных трейсов (0..4).
local function Resolve(key, f, old)
    local traces = 0

    if IsBorder(key) then
        f = FULL_WORLD
    else
        local s = VoxelSize
        local x = (band(key, GRID_MASK) - GRID_BIAS + 0.5) * s
        local y = (band(rshift(key, 10), GRID_MASK) - GRID_BIAS + 0.5) * s
        local z = (band(rshift(key, 20), GRID_MASK) - GRID_BIAS + 0.5) * s

        if band(f, CELL_KNOWN) == 0 then
            local hit, ent = RunTrace(x, y, z, x, y, z)
            traces = 1
            if hit == HIT_DYNAMIC then
                f = bor(f, CELL_KNOWN, SOLID_DYNAMIC)
                Portals.BindVoxelToEntity(key, ent)
            elseif hit ~= HIT_NONE then
                f = bor(f, CELL_KNOWN, SOLID_WORLD)
            else
                f = bor(f, CELL_KNOWN)
            end
        end

        if band(f, SOLID_WORLD) ~= 0 then
            -- Центр в статике: газ сюда не попадёт никогда, все грани — мир навсегда.
            f = bor(band(f, bnot(FACE_DYN_ALL)), FACE_KNOWN_ALL, FACE_WORLD_ALL)
        elseif band(f, SOLID_DYNAMIC) ~= 0 then
            -- Центр внутри двери/пропа: неизвестные грани закрыты той же сущностью (она уже привязана).
            local unknown = band(bnot(f), FACE_KNOWN_ALL)
            f = bor(f, unknown, lshift(unknown, 6))
        else
            for axis = 0, 2 do
                local knownBit = lshift(FACE_KNOWN_X, axis)
                if band(f, knownBit) == 0 then
                    local hit, ent
                    if axis == 0 then
                        hit, ent = RunTrace(x, y, z, x + s, y, z)
                    elseif axis == 1 then
                        hit, ent = RunTrace(x, y, z, x, y + s, z)
                    else
                        hit, ent = RunTrace(x, y, z, x, y, z + s)
                    end
                    traces = traces + 1

                    if hit == HIT_DYNAMIC then
                        f = bor(f, knownBit, lshift(FACE_DYN_X, axis))
                        Portals.BindVoxelToEntity(key, ent)
                    elseif hit == HIT_WORLD then
                        f = bor(f, knownBit, lshift(FACE_WORLD_X, axis))
                    elseif hit == HIT_SKY then
                        f = bor(f, knownBit, lshift(FACE_WORLD_X, axis), lshift(FACE_SKY_X, axis))
                    else
                        f = bor(f, knownBit)
                    end
                end
            end
        end
    end

    Collision[key] = f
    if old == nil then Spatial.CachedCount = Spatial.CachedCount + 1 end
    Stats.probes = Stats.probes + 1
    if f ~= old then CollisionChanged(key, old or 0, f) end
    return traces
end

--- Дозапекает ячейку (только неизвестные части). Возвращает число трейсов.
function Spatial.ProbeVoxel(key)
    if key < 0 or key > MAX_KEY then return 0 end
    local f = Collision[key]
    return Resolve(key, f or 0, f)
end

--- Сбрасывает динамический слой ячейки без трейса (мировые биты не трогает).
-- Событие изменения не шлётся: состояние становится «неизвестным» до следующего запекания.
function Spatial.ClearDynamicBlock(key)
    local f = Collision[key]
    if f == nil then return end
    local nf = ClearedFlags(f)
    if nf ~= f then Collision[key] = nf end
end

--- Атомарно: сброс динамического слоя + повторный трейс. Пока ячейка ждёт в очереди, солвер видит
-- прежнее состояние (а не «неизвестно»), поэтому соседние проёмы не «моргают» при движении двери.
function Spatial.RebakeVoxelCollision(key)
    if key < 0 or key > MAX_KEY then return 0 end
    local f = Collision[key]
    Stats.rebakes = Stats.rebakes + 1
    return Resolve(key, f and ClearedFlags(f) or 0, f)
end

--- Сколько трейсов (максимум) займёт RebakeVoxelCollision(key).
function Spatial.RebakeCost(key)
    local f = Collision[key]
    if f == nil then return 4 end
    return PendingCost(ClearedFlags(f))
end

--- Сколько трейсов (максимум) займёт ProbeVoxel(key).
function Spatial.ProbeCost(key)
    return PendingCost(Collision[key])
end

--- Ставит ячейку в очередь ленивого запекания (если в ней есть что трассировать).
function Spatial.RequestProbe(key)
    if key < 0 or key > MAX_KEY then return false end
    if PendingCost(Collision[key]) == 0 then return false end
    return QueuePush(ProbeQ, key)
end

--- Состояние грани из ячейки key в направлении dir (0..5, см. DIR_STRIDE):
--   1 — открыта, 0 — закрыта, 2 — закрыта небом (сток в атмосферу),
--  −1 — ещё не запечена (считать закрытой; запрос на запекание владельца грани уже поставлен).
function Spatial.FaceState(key, dir)
    local axis = rshift(dir, 1)
    local owner = key
    if band(dir, 1) == 1 then owner = key - AXIS_STRIDE[axis] end
    if owner < 0 then return 0 end

    local f = Collision[owner]
    if f == nil or band(f, lshift(FACE_KNOWN_X, axis)) == 0 then
        QueuePush(ProbeQ, owner)
        return -1
    end
    if band(f, lshift(FACE_BLOCK_X, axis)) == 0 then return 1 end
    if band(f, lshift(FACE_SKY_X, axis)) ~= 0 then return 2 end
    return 0
end

--- Ячейка известна и пригодна для газа (центр не внутри твёрдого).
function Spatial.IsCellOpen(key)
    local f = Collision[key]
    return f ~= nil and band(f, CELL_KNOWN) ~= 0 and band(f, SOLID_ANY) == 0
end

-- Ленивое запекание: не больше aether_probe_budget трейсов за тик (минимум конвара 4 ≥ стоимость
-- одной ячейки, так что очередь всегда продвигается) и не дольше QUEUE_TIME_GUARD.
hook.Add("Tick", "AetherGas.Spatial.ProbeQueue", function()
    local q = ProbeQ
    if q.count == 0 then return end

    local budget = CV.ProbeBudget:GetInt()
    local used = 0
    local deadline = SysTime() + C.QUEUE_TIME_GUARD

    while q.count > 0 do
        local key = q.buf[q.head + 1]
        local f = Collision[key]
        local cost = PendingCost(f)
        if cost > 0 and used + cost > budget then break end
        QueuePop(q)
        if cost > 0 then
            used = used + Resolve(key, f or 0, f)
            if SysTime() > deadline then break end
        end
    end
end)

---------------------------------------------------------------------------------------------------
-- 7. Полный сброс сетки (смена размера вокселя или маски решёток)
---------------------------------------------------------------------------------------------------
local function ApplyMask(gratesBlock)
    TrIn.mask = gratesBlock and bor(MASK_GAS_BASE, CONTENTS_GRATE) or MASK_GAS_BASE
end

function Spatial.Rebuild(size, gratesBlock)
    size = floor(tonumber(size) or C.VOXEL_SIZE_MIN)
    if size < C.VOXEL_SIZE_MIN then size = C.VOXEL_SIZE_MIN end
    if size > C.VOXEL_SIZE_MAX then size = C.VOXEL_SIZE_MAX end
    if gratesBlock == nil then gratesBlock = CV.GratesBlock:GetBool() end

    VoxelSize, InvSize = size, 1 / size
    Spatial.VoxelSize, Spatial.GratesBlock = size, gratesBlock
    ApplyMask(gratesBlock)

    table.Empty(Collision)
    Spatial.CachedCount = 0
    ResetPool()
    QueueClear(ProbeQ)

    hook.Run("AetherGas.GridRebuilt", size)
end

do
    local wantSize, wantGrates = CV.VoxelSize:GetInt(), CV.GratesBlock:GetBool()
    if Spatial.VoxelSize == nil or Spatial.VoxelSize ~= wantSize or Spatial.GratesBlock ~= wantGrates then
        Spatial.Rebuild(wantSize, wantGrates)
    else
        -- lua refresh: кэш сохранён, восстанавливаем upvalue из постоянного состояния.
        VoxelSize, InvSize = Spatial.VoxelSize, 1 / Spatial.VoxelSize
        ApplyMask(Spatial.GratesBlock)
    end
end

if SERVER then
    function Spatial.BroadcastGridReset(ply)
        net.Start(C.NET_GRID_RESET)
        net.WriteUInt(Spatial.VoxelSize, 8)
        net.WriteBool(Spatial.GratesBlock)
        if ply then net.Send(ply) else net.Broadcast() end
    end

    local function OnGridCVarChanged()
        local size, grates = CV.VoxelSize:GetInt(), CV.GratesBlock:GetBool()
        if size == Spatial.VoxelSize and grates == Spatial.GratesBlock then return end
        Spatial.Rebuild(size, grates)
        Spatial.BroadcastGridReset()
    end
    cvars.AddChangeCallback("aether_voxel_size", OnGridCVarChanged, "AetherGas.Spatial")
    cvars.AddChangeCallback("aether_grates_block", OnGridCVarChanged, "AetherGas.Spatial")
else
    -- Размер и маска приходят в самом сообщении: порядок доставки реплицируемого ConVar'а
    -- относительно net-сообщения не гарантирован.
    net.Receive(C.NET_GRID_RESET, function()
        local size = net.ReadUInt(8)
        local grates = net.ReadBool()
        Spatial.Rebuild(size, grates)
    end)
end
