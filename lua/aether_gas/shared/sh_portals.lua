-- lua/aether_gas/shared/sh_portals.lua
--[[
    Ядро порталов (shared): обратный индекс EntToVoxels, чёрный список разбитых стёкол и кольцевая
    очередь перепроверки (не более 16 трейсов за тик).

    Почему ядро shared, а не только в sv_portals.lua: клиент ведёт собственный кэш коллизий (трассирует
    тот же BSP и те же сетевые сущности) и симулирует газ детерминированно по событиям сервера.
    Обнаружение событий (AcceptInput, урон, удаление, опрос дверей) — только на сервере
    (sv_portals.lua); сюда приходит уже готовое событие [kind, entIndex], и обе стороны применяют
    его одной и той же функцией ApplyEvent → кэши сервера и клиента расходятся минимально.

    Инвалидация сущности = (a) все воксели из её корзины EntToVoxels — там, где она что-то
    блокировала, + (b) все ЗАКЭШИРОВАННЫЕ воксели внутри её текущего AABB. Пункт (b) обязателен:
    открытая дверь ничего не блокирует и потому ни к чему не привязана; без него закрывшаяся
    дверь не инвалидировала бы ни одного вокселя и газ шёл бы сквозь неё вечно.
]]

local AetherGas = AetherGas
local Portals   = AetherGas.Portals
local Spatial   = AetherGas.Spatial
local C         = AetherGas.Const

local bor, lshift = bit.bor, bit.lshift
local max, min    = math.max, math.min
local IsValid     = IsValid
local Entity      = Entity
local pairs       = pairs
local next        = next
local SysTime     = SysTime

local QueuePush, QueuePop, QueueClear = Spatial.QueuePush, Spatial.QueuePop, Spatial.QueueClear

Portals.EntToVoxels       = Portals.EntToVoxels or {}        -- [entIndex] = { [voxelKey] = true }
Portals.ShatteredSurfaces = Portals.ShatteredSurfaces or {}  -- [entIndex] = true (трейсы игнорируют)
Portals.RecalcQ           = Portals.RecalcQ or Spatial.QueueNew(2048)
Portals.Stats             = Portals.Stats or { invalidated = 0, rebaked = 0, traces = 0, events = 0 }

local EntToVoxels = Portals.EntToVoxels
local Shattered   = Portals.ShatteredSurfaces
local RecalcQ     = Portals.RecalcQ
local Stats       = Portals.Stats
local Collision   = Spatial.Collision

-- Типы событий (3 бита в сетевом пакете)
local EV_MOVED, EV_REMOVED, EV_SHATTERED, EV_DYN_RESET = 0, 1, 2, 3
Portals.EV_MOVED, Portals.EV_REMOVED, Portals.EV_SHATTERED, Portals.EV_DYN_RESET =
    EV_MOVED, EV_REMOVED, EV_SHATTERED, EV_DYN_RESET

local GRID_MASK = Spatial.GRID_MASK
-- Предел перебора AABB: огромные func_movelinear (лифтовые платформы) обслуживаются только корзиной.
local MAX_SWEEP_CELLS = 16384

--- Привязка вокселя к динамической сущности. Вызывается из sh_spatial при попадании трейса.
function Portals.BindVoxelToEntity(key, ent)
    local idx = ent:EntIndex()
    if idx <= 0 then return end
    local bucket = EntToVoxels[idx]
    if not bucket then
        bucket = {}
        EntToVoxels[idx] = bucket
    end
    bucket[key] = true
end

--- Ставит закэшированную ячейку в очередь перепроверки.
function Portals.InvalidateVoxel(key)
    if Collision[key] == nil then return false end
    return QueuePush(RecalcQ, key)
end

--- Ставит в очередь все закэшированные ячейки, чьи грани могут пересекать AABB [x0..x1]×[y0..y1]×[z0..z1].
-- Грань между g−1 и g принадлежит ячейке g−1, поэтому диапазон расширен на одну ячейку в минус.
function Portals.InvalidateBox(x0, y0, z0, x1, y1, z1)
    local gx0, gy0, gz0 = Spatial.WorldToGrid(x0, y0, z0)
    local gx1, gy1, gz1 = Spatial.WorldToGrid(x1, y1, z1)
    gx0, gy0, gz0 = max(gx0 - 1, 0), max(gy0 - 1, 0), max(gz0 - 1, 0)
    gx1, gy1, gz1 = min(gx1, GRID_MASK), min(gy1, GRID_MASK), min(gz1, GRID_MASK)
    if gx1 < gx0 or gy1 < gy0 or gz1 < gz0 then return 0 end
    if (gx1 - gx0 + 1) * (gy1 - gy0 + 1) * (gz1 - gz0 + 1) > MAX_SWEEP_CELLS then return 0 end

    local n = 0
    for gz = gz0, gz1 do
        local zPart = lshift(gz, 20)
        for gy = gy0, gy1 do
            local yzPart = bor(zPart, lshift(gy, 10))
            for gx = gx0, gx1 do
                local key = bor(yzPart, gx)
                if Collision[key] ~= nil and QueuePush(RecalcQ, key) then n = n + 1 end
            end
        end
    end
    return n
end

--- Инвалидирует всё, что могло измениться из-за сущности idx.
-- ent    — живая сущность для обхода её AABB (nil — сущности уже нет, хватает корзины)
-- unbind — удалить корзину целиком (сущность удалена/разбита). Иначе корзина просто очищается:
--          перезапекание заново привяжет те воксели, которые сущность всё ещё блокирует.
function Portals.InvalidateEntity(idx, ent, unbind)
    local n = 0
    local bucket = EntToVoxels[idx]
    if bucket then
        for key in pairs(bucket) do
            if QueuePush(RecalcQ, key) then n = n + 1 end
            bucket[key] = nil
        end
        if unbind then EntToVoxels[idx] = nil end
    end

    if ent ~= nil and IsValid(ent) then
        -- WorldSpaceAABB выделяет два Vector: путь событийный (раз в 0.15 с на движущуюся дверь).
        local mins, maxs = ent:WorldSpaceAABB()
        n = n + Portals.InvalidateBox(mins.x, mins.y, mins.z, maxs.x, maxs.y, maxs.z)
    end

    Stats.invalidated = Stats.invalidated + n
    return n
end

--- Сброс всего динамического слоя (очистка карты). Мировой кэш сохраняется; динамические грани
-- станут «неизвестными» и дозапекутся лениво, когда к ним подойдёт газ.
function Portals.ResetDynamic()
    local clear = Spatial.ClearDynamicBlock
    for key in pairs(Collision) do clear(key) end
    table.Empty(EntToVoxels)
    table.Empty(Shattered)
    QueueClear(RecalcQ)
    Spatial.MarkAllDirty()
end

--- Применяет событие порталов. Одна и та же функция работает на сервере (сразу при обнаружении)
-- и на клиенте (по сетевому пакету), поэтому кэши обеих сторон меняются одинаково.
function Portals.ApplyEvent(kind, idx)
    Stats.events = Stats.events + 1
    if kind == EV_MOVED then
        Portals.InvalidateEntity(idx, Entity(idx), false)
    elseif kind == EV_REMOVED then
        Shattered[idx] = nil
        Portals.InvalidateEntity(idx, nil, true)
    elseif kind == EV_SHATTERED then
        Shattered[idx] = true
        Portals.InvalidateEntity(idx, Entity(idx), true)
    elseif kind == EV_DYN_RESET then
        Portals.ResetDynamic()
    end
end

hook.Add("AetherGas.GridRebuilt", "AetherGas.Portals", function()
    table.Empty(EntToVoxels)
    QueueClear(RecalcQ)
end)

-- Амортизированная перепроверка: строго не более RECALC_TRACES_PER_TICK трейсов за тик.
-- Стоимость ячейки (0..4 трейса) известна заранее, поэтому лимит не превышается даже на одну ячейку.
hook.Add("Tick", "AetherGas.Portals.Recalc", function()
    local q = RecalcQ
    if q.count == 0 then return end

    local limit = C.RECALC_TRACES_PER_TICK
    local used = 0
    local deadline = SysTime() + C.QUEUE_TIME_GUARD
    local onRebake = AetherGas.Debug.OnRebake   -- nil, пока отладка выключена

    while q.count > 0 do
        local key = q.buf[q.head + 1]
        local cost = Spatial.RebakeCost(key)
        if used + cost > limit then break end
        QueuePop(q)

        local before = Collision[key]
        used = used + Spatial.RebakeVoxelCollision(key)
        Stats.rebaked = Stats.rebaked + 1
        if onRebake then onRebake(key, before or 0, Collision[key]) end

        if SysTime() > deadline then break end
    end
    Stats.traces = Stats.traces + used
end)

if CLIENT then
    -- Клиентские сущности интерполируются в прошлом (cl_interp ≈ 0.1 с), поэтому последнее событие
    -- MOVED может прийти раньше, чем клиентская дверь доедет до финальной позиции. Через SETTLE_DELAY
    -- после последнего события клиент сам перепроверяет сущность ещё раз — кэши сходятся.
    local SETTLE_DELAY = 0.35
    Portals.ClientSettle = Portals.ClientSettle or {}   -- [idx] = RealTime() повторной проверки
    local ClientSettle = Portals.ClientSettle

    net.Receive(C.NET_PORTAL, function()
        local n = net.ReadUInt(8)
        local settleAt = RealTime() + SETTLE_DELAY
        for _ = 1, n do
            local kind = net.ReadUInt(3)
            local idx = net.ReadUInt(13)
            Portals.ApplyEvent(kind, idx)
            if kind == EV_MOVED then
                ClientSettle[idx] = settleAt
            elseif kind == EV_REMOVED or kind == EV_SHATTERED then
                ClientSettle[idx] = nil
            elseif kind == EV_DYN_RESET then
                table.Empty(ClientSettle)
            end
        end
    end)

    timer.Create("AetherGas.Portals.ClientSettle", 0.1, 0, function()
        if next(ClientSettle) == nil then return end
        local now = RealTime()
        for idx, at in pairs(ClientSettle) do
            if now >= at then
                ClientSettle[idx] = nil
                Portals.InvalidateEntity(idx, Entity(idx), false)
            end
        end
    end)

    -- Удаление на клиенте может прийти позже события сервера: перепроверка, выполненная до
    -- исчезновения клиентской сущности, снова привязала бы к ней воксели.
    hook.Add("EntityRemoved", "AetherGas.Portals.ClientRemoved", function(ent, fullUpdate)
        if fullUpdate then return end
        local idx = ent:EntIndex()
        if idx > 0 and EntToVoxels[idx] then
            Portals.InvalidateEntity(idx, nil, true)
        end
    end)

    -- Сервер в ответ пришлёт параметры сетки и список уже разбитых стёкол (их клиент сам не узнает).
    hook.Add("InitPostEntity", "AetherGas.Portals.ClientReady", function()
        net.Start(C.NET_CLIENT_READY)
        net.SendToServer()
    end)
end
