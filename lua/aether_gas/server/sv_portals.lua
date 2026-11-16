-- lua/aether_gas/server/sv_portals.lua
--[[
    Серверное обнаружение событий порталов: двери, окна, разрушаемые браши, крупные физпропы.
    Обнаруженное событие применяется локально (Portals.ApplyEvent из sh_portals.lua) и в конце тика
    уходит клиентам одним пакетом: N × [kind:3][entIndex:13] = 2 байта на событие.

    Источники событий (карта целиком не опрашивается никогда):
      • AcceptInput     — Open/Close/Toggle дверей, Break/Shatter стёкол, Enable/Disable func_brush…
      • PlayerUse       — игрок открывает дверь «E»: это вызов Use(), а не input, AcceptInput его не видит.
      • Сторож дверей   — раз в 0.25 с читает одно поле состояния у дверей из заранее собранного списка
                          (≈1–2 мкс на дверь). Ловит то, что не проходит через input: NPC открывают
                          prop_door_rotating напрямую, func_door с флагом «Touch opens» — касанием.
                          Работает, только пока в кэше есть хоть одна ячейка.
      • Движущиеся      — раз в 0.15 с перепроверяют свои воксели (корзина + AABB), пока не остановятся:
                          prop_door_rotating: m_eDoorState ∈ {0 закрыта, 2 открыта};
                          func_door(_rotating): m_toggle_state ∈ {0 TS_AT_TOP, 1 TS_AT_BOTTOM}
                          (у брашевых дверей поля m_eDoorState нет вовсе!);
                          func_movelinear: поля состояния нет → нулевая линейная и угловая скорость;
                          физпроп: уснул или заморожен.
      • EntityRemoved   — func_breakable, prop_physics и всё прочее, что исчезает при разрушении.
      • Стекло          — func_breakable_surf при разрушении НЕ удаляется. Кандидаты приходят из
                          EntityTakeDamage, PostEntityFireBullets и AcceptInput, а факт разрушения
                          подтверждается на следующем тике по m_bIsBroken. EntityFireBullets не
                          используется: возврат true из него обрывает цепочку хуков других аддонов
                          и требует нового замыкания-обёртки на каждую пулю.
]]

local AetherGas = AetherGas
local Portals   = AetherGas.Portals
local Spatial   = AetherGas.Spatial
local C         = AetherGas.Const

local IsValid      = IsValid
local Entity       = Entity
local pairs        = pairs
local next         = next
local min          = math.min
local string_lower = string.lower

local EV_MOVED, EV_REMOVED, EV_SHATTERED, EV_DYN_RESET =
    Portals.EV_MOVED, Portals.EV_REMOVED, Portals.EV_SHATTERED, Portals.EV_DYN_RESET

---------------------------------------------------------------------------------------------------
-- Виды отслеживаемых сущностей
---------------------------------------------------------------------------------------------------
local KIND_DOOR_PROP  = 1  -- prop_door_rotating
local KIND_DOOR_BRUSH = 2  -- func_door, func_door_rotating
local KIND_LINEAR     = 3  -- func_movelinear
local KIND_PHYS       = 4  -- физпропы (MOVETYPE_VPHYSICS), достаточно крупные, чтобы держать газ
local KIND_TOGGLE     = 5  -- мгновенное переключение коллизии: func_brush, func_wall_toggle, prop_dynamic

Portals.KIND_NAMES = { "door_prop", "door_brush", "linear", "physics", "toggle" }

local TRACKED_CLASS = {
    prop_door_rotating = KIND_DOOR_PROP,
    func_door          = KIND_DOOR_BRUSH,
    func_door_rotating = KIND_DOOR_BRUSH,
    func_movelinear    = KIND_LINEAR,
    func_brush         = KIND_TOGGLE,
    func_wall_toggle   = KIND_TOGGLE,
    prop_dynamic       = KIND_TOGGLE,
}

-- Имена input'ов в Source регистронезависимы — сравниваем в нижнем регистре.
local TRACKED_INPUT = {
    [KIND_DOOR_PROP]  = { open = true, close = true, toggle = true, openawayfrom = true },
    [KIND_DOOR_BRUSH] = { open = true, close = true, toggle = true },
    [KIND_LINEAR]     = { open = true, close = true, setposition = true },
    [KIND_TOGGLE]     = { enable = true, disable = true, toggle = true,
                          enablecollision = true, disablecollision = true },
}

local MOVER_POLL        = 0.15
local MOVER_MIN_POLLS   = 2     -- AcceptInput приходит ДО начала движения: минимум две перепроверки
local MOVER_MAX_POLLS   = 400   -- 60 с: застрявшая дверь снимается, сторож вернёт её при движении
local WATCHDOG_PERIOD   = 0.25
local GLASS_CHECK_TICKS = 3     -- сколько тиков ждать подтверждения m_bIsBroken
local NET_BATCH         = 255   -- событий в одном сообщении (счётчик — 8 бит)

Portals.Movers        = Portals.Movers or {}         -- [idx] = ent
Portals.MoverKind     = Portals.MoverKind or {}      -- [idx] = KIND_*
Portals.MoverPolls    = Portals.MoverPolls or {}     -- [idx] = перепроверок с момента активации
Portals.WatchedDoors  = Portals.WatchedDoors or {}   -- [idx] = ent (двери и func_movelinear карты)
Portals.WatchedKind   = Portals.WatchedKind or {}    -- [idx] = KIND_*
Portals.DoorLastState = Portals.DoorLastState or {}  -- [idx] = последнее прочитанное состояние
Portals.GlassPending  = Portals.GlassPending or {}   -- [idx] = оставшиеся тики проверки
Portals.ReadyClients  = Portals.ReadyClients or {}   -- [UserID] = true

local Movers, MoverKind, MoverPolls = Portals.Movers, Portals.MoverKind, Portals.MoverPolls
local WatchedDoors, WatchedKind, DoorLastState = Portals.WatchedDoors, Portals.WatchedKind, Portals.DoorLastState
local GlassPending = Portals.GlassPending
local EntToVoxels  = Portals.EntToVoxels
local Shattered    = Portals.ShatteredSurfaces

---------------------------------------------------------------------------------------------------
-- Буфер событий тика. Повтор того же [kind, idx] в пределах тика отбрасывается (локально и в сети).
---------------------------------------------------------------------------------------------------
local NetKind, NetIdx, NetSeen = {}, {}, {}
local NetCount = 0

local function Emit(kind, idx)
    local tag = idx * 8 + kind
    if NetSeen[tag] then return end
    NetSeen[tag] = true
    Portals.ApplyEvent(kind, idx)
    NetCount = NetCount + 1
    NetKind[NetCount] = kind
    NetIdx[NetCount] = idx
end
Portals.Emit = Emit

local function FlushNet()
    local first = 1
    while first <= NetCount do
        local last = min(first + NET_BATCH - 1, NetCount)
        net.Start(C.NET_PORTAL)
        net.WriteUInt(last - first + 1, 8)
        for i = first, last do
            net.WriteUInt(NetKind[i], 3)
            net.WriteUInt(NetIdx[i], 13)
        end
        net.Broadcast()
        first = last + 1
    end
    NetCount = 0
    table.Empty(NetSeen)
end

---------------------------------------------------------------------------------------------------
-- Состояние дверей
---------------------------------------------------------------------------------------------------
local function ReadDoorState(ent, kind)
    if kind == KIND_DOOR_PROP then return ent:GetInternalVariable("m_eDoorState") end
    if kind == KIND_DOOR_BRUSH then return ent:GetInternalVariable("m_toggle_state") end
    return nil
end

local function IsSettled(ent, kind)
    if kind == KIND_DOOR_PROP then
        local s = ent:GetInternalVariable("m_eDoorState")     -- 0 закрыта, 1 открывается, 2 открыта, 3 закрывается
        if s ~= nil then return s == 0 or s == 2 end
    elseif kind == KIND_DOOR_BRUSH then
        local s = ent:GetInternalVariable("m_toggle_state")   -- 0 AT_TOP, 1 AT_BOTTOM, 2 GOING_UP, 3 GOING_DOWN
        if s ~= nil then return s == 0 or s == 1 end
    elseif kind == KIND_PHYS then
        local phys = ent:GetPhysicsObject()
        return not IsValid(phys) or phys:IsAsleep() or not phys:IsMotionEnabled()
    elseif kind == KIND_TOGGLE then
        return true
    end
    -- func_movelinear и двери без читаемого поля: покой = нулевые линейная и угловая скорости.
    return ent:GetVelocity():LengthSqr() < 0.25 and ent:GetLocalAngularVelocity():IsZero()
end

local function RemoveMover(idx)
    Movers[idx], MoverKind[idx], MoverPolls[idx] = nil, nil, nil
end

--- Начинает (или перезапускает) слежение за движущейся сущностью и сразу инвалидирует её воксели.
function Portals.TrackMover(ent, kind)
    local idx = ent:EntIndex()
    if idx <= 0 then return end
    Movers[idx], MoverKind[idx], MoverPolls[idx] = ent, kind, 0
    Emit(EV_MOVED, idx)
end

local function WatchIfDoor(ent)
    local kind = TRACKED_CLASS[ent:GetClass()]
    if kind ~= KIND_DOOR_PROP and kind ~= KIND_DOOR_BRUSH and kind ~= KIND_LINEAR then return end
    local idx = ent:EntIndex()
    if idx <= 0 then return end
    WatchedDoors[idx], WatchedKind[idx], DoorLastState[idx] = ent, kind, nil
end

local function ScanDoors()
    local all = ents.GetAll()
    for i = 1, #all do WatchIfDoor(all[i]) end
end

local function PollMovers()
    for idx, ent in pairs(Movers) do
        if not IsValid(ent) then
            RemoveMover(idx)
        else
            Emit(EV_MOVED, idx)
            local polls = MoverPolls[idx] + 1
            MoverPolls[idx] = polls
            if polls >= MOVER_MAX_POLLS or (polls >= MOVER_MIN_POLLS and IsSettled(ent, MoverKind[idx])) then
                RemoveMover(idx)
                -- Финальное состояние запоминаем, чтобы сторож не принял его за новое изменение.
                local wk = WatchedKind[idx]
                if wk then DoorLastState[idx] = ReadDoorState(ent, wk) end
            end
        end
    end
end

local function Watchdog()
    if Spatial.CachedCount == 0 then return end

    for idx, ent in pairs(WatchedDoors) do
        if not IsValid(ent) then
            WatchedDoors[idx], WatchedKind[idx], DoorLastState[idx] = nil, nil, nil
        elseif not Movers[idx] then
            local kind = WatchedKind[idx]
            local state = ReadDoorState(ent, kind)
            local last = DoorLastState[idx]
            DoorLastState[idx] = state
            -- Смена состояния между проверками (быстрая дверь успела открыться целиком) или движение сейчас.
            if (last ~= nil and state ~= last) or not IsSettled(ent, kind) then
                Portals.TrackMover(ent, kind)
            end
        end
    end

    -- Привязанные крупные физпропы: их могли сдвинуть телом или другим пропом без всяких хуков.
    for idx in pairs(EntToVoxels) do
        if not Movers[idx] then
            local ent = Entity(idx)
            if IsValid(ent) and ent:GetMoveType() == MOVETYPE_VPHYSICS then
                local phys = ent:GetPhysicsObject()
                if IsValid(phys) and phys:IsMotionEnabled() and not phys:IsAsleep() then
                    Portals.TrackMover(ent, KIND_PHYS)
                end
            end
        end
    end
end

---------------------------------------------------------------------------------------------------
-- Стекло
---------------------------------------------------------------------------------------------------
local function QueueGlassCheck(idx)
    if idx > 0 and not Shattered[idx] then GlassPending[idx] = GLASS_CHECK_TICKS end
end

local function ProcessGlass()
    for idx, ttl in pairs(GlassPending) do
        local ent = Entity(idx)
        if not IsValid(ent) or Shattered[idx] then
            GlassPending[idx] = nil
        else
            local broken = ent:GetInternalVariable("m_bIsBroken")
            -- Поле недоступно (nil) → считаем разбитым: любое попадание по func_breakable_surf его колет.
            if broken ~= false and broken ~= 0 then
                GlassPending[idx] = nil
                Emit(EV_SHATTERED, idx)
            elseif ttl <= 1 then
                GlassPending[idx] = nil
            else
                GlassPending[idx] = ttl - 1
            end
        end
    end
end

---------------------------------------------------------------------------------------------------
-- Хуки
---------------------------------------------------------------------------------------------------
hook.Add("AcceptInput", "AetherGas.Portals.Input", function(ent, input)
    if not IsValid(ent) then return end
    local class = ent:GetClass()

    if class == "func_breakable_surf" then
        local inp = string_lower(input)
        if inp == "shatter" or inp == "break" then QueueGlassCheck(ent:EntIndex()) end
        return
    end

    local kind = TRACKED_CLASS[class]
    if kind and TRACKED_INPUT[kind][string_lower(input)] then
        Portals.TrackMover(ent, kind)
    end
end)

hook.Add("PlayerUse", "AetherGas.Portals.Use", function(_, ent)
    if not IsValid(ent) then return end
    local kind = TRACKED_CLASS[ent:GetClass()]
    if (kind == KIND_DOOR_PROP or kind == KIND_DOOR_BRUSH or kind == KIND_LINEAR) and not Movers[ent:EntIndex()] then
        Portals.TrackMover(ent, kind)
    end
end)

hook.Add("OnEntityCreated", "AetherGas.Portals.Watch", function(ent)
    if IsValid(ent) then WatchIfDoor(ent) end
end)

hook.Add("InitPostEntity", "AetherGas.Portals.Scan", ScanDoors)

hook.Add("EntityRemoved", "AetherGas.Portals.Removed", function(ent)
    local idx = ent:EntIndex()
    if idx <= 0 then return end

    RemoveMover(idx)
    WatchedDoors[idx], WatchedKind[idx], DoorLastState[idx] = nil, nil, nil
    GlassPending[idx] = nil

    if EntToVoxels[idx] or Shattered[idx] then
        Emit(EV_REMOVED, idx)
    end
end)

hook.Add("EntityTakeDamage", "AetherGas.Portals.Damage", function(target)
    if not IsValid(target) then return end
    local idx = target:EntIndex()
    local class = target:GetClass()
    if class == "func_breakable_surf" then
        QueueGlassCheck(idx)
        return
    end
    -- Procedural Wall Destruction: стена пробивается без удаления (перестраивает физику) — перепроверить.
    if class == "proceduralwall" then
        Portals.TrackMover(target, KIND_TOGGLE)
        return
    end
    -- Взрыв/выстрел толкнул крупный проп, который держит газ.
    if EntToVoxels[idx] and not Movers[idx] and target:GetMoveType() == MOVETYPE_VPHYSICS then
        Portals.TrackMover(target, KIND_PHYS)
    end
end)

-- Только чтение: пуля уже прошла, data не меняем и ничего не возвращаем.
hook.Add("PostEntityFireBullets", "AetherGas.Portals.Bullets", function(_, data)
    local tr = data and data.Trace
    if not tr then return end
    local ent = tr.Entity
    if IsValid(ent) and ent:GetClass() == "func_breakable_surf" then
        QueueGlassCheck(ent:EntIndex())
    end
end)

local function TrackPhysics(ent)
    if not IsValid(ent) or ent:GetMoveType() ~= MOVETYPE_VPHYSICS then return end
    -- Мелочь трейсы и так игнорируют — следить за ней незачем.
    if not Spatial.IsGasBlocker(ent) then return end
    Portals.TrackMover(ent, KIND_PHYS)
end

hook.Add("OnPhysgunPickup",    "AetherGas.Portals.Phys", function(_, ent) TrackPhysics(ent) end)
hook.Add("PhysgunDrop",        "AetherGas.Portals.Phys", function(_, ent) TrackPhysics(ent) end)
hook.Add("GravGunOnPickedUp",  "AetherGas.Portals.Phys", function(_, ent) TrackPhysics(ent) end)
hook.Add("GravGunOnDropped",   "AetherGas.Portals.Phys", function(_, ent) TrackPhysics(ent) end)
hook.Add("OnPhysgunFreeze",    "AetherGas.Portals.Phys", function(_, _, ent) TrackPhysics(ent) end)
hook.Add("PlayerUnfrozeObject","AetherGas.Portals.Phys", function(_, ent) TrackPhysics(ent) end)
hook.Add("PlayerSpawnedProp",  "AetherGas.Portals.Phys", function(_, _, ent) TrackPhysics(ent) end)
hook.Add("PlayerSpawnedSENT",  "AetherGas.Portals.Phys", function(_, ent) TrackPhysics(ent) end)

-- Очистка карты: сущности пересоздаются, мировой кэш остаётся валидным, динамический — нет.
hook.Add("PostCleanupMap", "AetherGas.Portals.Cleanup", function()
    table.Empty(Movers)
    table.Empty(MoverKind)
    table.Empty(MoverPolls)
    table.Empty(GlassPending)
    Emit(EV_DYN_RESET, 0)
    ScanDoors()
end)

hook.Add("Tick", "AetherGas.Portals.Server", function()
    if next(GlassPending) ~= nil then ProcessGlass() end
    if NetCount > 0 then FlushNet() end
end)

timer.Create("AetherGas.Portals.PollMovers", MOVER_POLL, 0, PollMovers)
timer.Create("AetherGas.Portals.Watchdog", WATCHDOG_PERIOD, 0, Watchdog)

-- Новый клиент: параметры сетки + уже разбитые стёкла (сам он их не узнает — сущность не удаляется).
net.Receive(C.NET_CLIENT_READY, function(_, ply)
    if not IsValid(ply) then return end
    local uid = ply:UserID()
    if Portals.ReadyClients[uid] then return end
    Portals.ReadyClients[uid] = true

    Spatial.BroadcastGridReset(ply)

    local list, n = {}, 0
    for idx in pairs(Shattered) do
        n = n + 1
        list[n] = idx
    end
    local first = 1
    while first <= n do
        local last = min(first + NET_BATCH - 1, n)
        net.Start(C.NET_PORTAL)
        net.WriteUInt(last - first + 1, 8)
        for i = first, last do
            net.WriteUInt(EV_SHATTERED, 3)
            net.WriteUInt(list[i], 13)
        end
        net.Send(ply)
        first = last + 1
    end

    -- Остальные модули (солвер: активные источники газа) досылают своё состояние.
    hook.Run("AetherGas.ClientReady", ply)
end)

-- lua refresh: OnEntityCreated для уже существующих сущностей не повторится.
ScanDoors()
