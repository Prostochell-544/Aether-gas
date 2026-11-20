-- lua/aether_gas/shared/sh_fire.lua
--[[
    Огонь ↔ газ. Очаги: vFire (класс vfire, события vFireCreated/vFireRemoved), env_fire (Fire Tool, карты),
    entityflame (Entity:Ignite, Fire Tool «Ignite target», горящие NPC/пропы).

    Раз в FIRE_PERIOD (сервер), не больше MAX_FIRES очагов за проход (по кругу):
      • дым: очаг выпускает co_smoke (дым пожара, 250 °C — поднимается, остыв, заполняет помещение сверху);
        количество — по размеру очага (vFire: состояние 1..7, env_fire: firesize, entityflame: объём родителя)
        × aether_fire_smoke; выбросы в одном вокселе складываются. Дым идёт непрерывным источником
        (Solver.AddSource) в воксель над очагом, а не порциями раз в FIRE_PERIOD: порции давали пульсацию
        плотности у огня — облако мигало. Источник пересоздаётся, только если сила очагов в вокселе
        изменилась больше чем на RATE_TOL, и снимается, когда очагов в вокселе не осталось;
      • поджиг: горючий газ в вокселе очага или над ним детонирует (только если горючее было последние 2 с);
      • тушение: инертный газ (extinguishes: CO2, азот) ≥ 0.25 гасит очаг — vFire мягко (SoftExtinguish),
        env_fire входом Extinguish, entityflame — Extinguish родителя.
    vFire: хук vFireOnCalculateWind — пламя клонится по ветру Aether (aether_vfire_wind), чтобы огонь и дым
    сносило в одну сторону. Детонация газа разбрасывает огонь vFire — в sh_solver (Detonate).
]]

local AetherGas = AetherGas
local Solver  = AetherGas.Solver
local Spatial = AetherGas.Spatial
local CV      = AetherGas.CVar
local P       = AetherGas.GasParams

-- Ветер vFire (оба реалма: GetWindVector пламени вызывается и на клиенте). Длина ≤ 1 — сила по шкале vFire.
local WindVec = Vector(0, 0, 0)
hook.Add("vFireOnCalculateWind", "AetherGas.Fire.Wind", function()
    if not CV.VFireWind:GetBool() then return end
    local wx, wy = Solver.WindX or 0, Solver.WindY or 0
    local speed = math.sqrt(wx * wx + wy * wy)
    if speed < 1 then return end            -- безветрие Aether — у vFire свой ветер
    local k = math.min(1, speed / 300) / speed
    WindVec:SetUnpacked(wx * k, wy * k, 0)
    return WindVec
end)

if CLIENT then return end

local FIRE_PERIOD     = 0.5
local MAX_FIRES       = 96      -- очагов за проход; остальные — в следующий
local EXTINGUISH_CONC = 0.25
local SMOKE_TEMP      = 250
local SMOKE_RISE      = Vector(0, 0, 60)

AetherGas.Fires = AetherGas.Fires or {}   -- [ent] = вид: 1 vfire, 2 env_fire, 3 entityflame
local Fires = AetherGas.Fires
local KIND = { vfire = 1, env_fire = 2, entityflame = 3 }

local function Track(ent)
    local k = IsValid(ent) and KIND[ent:GetClass()]
    if k then Fires[ent] = k end
end
hook.Add("OnEntityCreated", "AetherGas.Fire.Track", function(ent)
    timer.Simple(0, function() Track(ent) end)
end)
hook.Add("EntityRemoved", "AetherGas.Fire.Track", function(ent) Fires[ent] = nil end)
for cls in pairs(KIND) do
    for _, e in ipairs(ents.FindByClass(cls)) do Track(e) end
end

--- Сила очага 0..~3 (единиц дыма за проход до множителя).
local function FireSize(ent, kind)
    if kind == 1 then
        local st = ent.GetFireState and ent:GetFireState() or 1
        return 0.12 * st
    elseif kind == 2 then
        local size = tonumber(ent:GetInternalVariable("m_flFireSize")) or 64
        return math.Clamp(size / 64, 0.3, 3) * 0.35
    end
    local parent = ent:GetParent()
    if not IsValid(parent) then return 0.2 end
    local mins, maxs = parent:OBBMins(), parent:OBBMaxs()
    local vol = (maxs.x - mins.x) * (maxs.y - mins.y) * (maxs.z - mins.z)
    return math.Clamp(vol / 60000, 0.15, 1.5)
end

local function Extinguish(ent, kind)
    if kind == 1 then
        if ent.SoftExtinguish and ent.life then ent:SoftExtinguish(ent.life * 0.5 + 1) end
    elseif kind == 2 then
        ent:Fire("Extinguish")
    else
        local parent = ent:GetParent()
        if IsValid(parent) and parent.Extinguish then parent:Extinguish() else ent:Remove() end
    end
end

local SmokeAmt, SmokeKeys = {}, {}   -- переиспользуемые: ключ вокселя → количество дыма за проход; список ключей
local nKeys = 0                      -- ключей за текущий круг обхода (круг может занять несколько проходов)
local SrcPos = Vector(0, 0, 0)
local cursor
local RATE_TOL = 0.25                -- относительное изменение силы, при котором источник пересоздаётся
local MAX_RATE = 8                   -- концентрации/с на воксель (раньше: не больше 4 за проход 0.5 с)

-- Источники дыма над очагами: ключ вокселя → id источника солвера и его сила. Переживают hot reload.
AetherGas.FireSrcId = AetherGas.FireSrcId or {}
AetherGas.FireSrcRate = AetherGas.FireSrcRate or {}
local SrcId, SrcRate = AetherGas.FireSrcId, AetherGas.FireSrcRate

local function StopSmoke(k)
    if Solver.Sources[SrcId[k]] then Solver.StopSource(SrcId[k]) end
    SrcId[k], SrcRate[k] = nil, nil
end

--- Конец круга обхода: источники приводятся к накопленным выбросам, накопление обнуляется.
local function SyncSmoke(smokeId)
    for i = 1, nKeys do
        local k = SmokeKeys[i]
        local rate = math.min(SmokeAmt[k] / FIRE_PERIOD, MAX_RATE)
        local old = SrcRate[k]
        -- источник жив (aether_clear снимает все) и сила почти та же — оставляем
        if not (old and Solver.Sources[SrcId[k]] and math.abs(rate - old) <= old * RATE_TOL) then
            if SrcId[k] then StopSmoke(k) end
            SrcPos:SetUnpacked(Spatial.VoxelCenter(k))
            local id = Solver.AddSource(smokeId, SrcPos, rate, 0, SMOKE_TEMP, SMOKE_RISE)
            if id then SrcId[k], SrcRate[k] = id, rate end
        end
    end
    for k in pairs(SrcId) do
        if SmokeAmt[k] == nil then StopSmoke(k) end   -- очагов в вокселе больше нет
    end
    for i = 1, nKeys do
        SmokeAmt[SmokeKeys[i]], SmokeKeys[i] = nil, nil
    end
    nKeys = 0
end

--- Газ у очага: тушение инертным газом (true — очаг потушен) или поджиг горючего.
local function GasAtFire(ent, kind, key, flammable)
    local KeyIndex, Gas, Conc = Solver.KeyIndex, Spatial.Gas, Spatial.Conc
    for dz = 0, 1 do
        local k = key + dz * Spatial.Z_STRIDE
        local idx = KeyIndex(k, false)
        local g = idx and Gas[idx] or 0
        if g ~= 0 then
            local def = AetherGas.GasById[g]
            if def and def.extinguishes and Conc[idx] >= EXTINGUISH_CONC then
                Extinguish(ent, kind)
                return true
            elseif flammable and Conc[idx] >= P.FlameMin[g] and Conc[idx] <= P.FlameMax[g] then
                Solver.BroadcastIgnite(k)
            end
        end
    end
    return false
end

timer.Create("AetherGas.Fire.Think", FIRE_PERIOD, 0, function()
    local smokeId = AetherGas.GetGasId("co_smoke")
    if not CV.Enabled:GetBool() or next(Fires) == nil then
        if next(SrcId) ~= nil or nKeys > 0 then   -- огня нет (или Aether выключен) — снять весь дым над ним
            for i = 1, nKeys do SmokeAmt[SmokeKeys[i]], SmokeKeys[i] = nil, nil end
            nKeys, cursor = 0, nil
            SyncSmoke(smokeId)
        end
        return
    end
    local smokeMul = CV.FireSmoke:GetFloat()
    local flammable = CurTime() - (Solver.FlammableSeen or -100) <= 2
    local hasGas = Spatial.Pool.used > 0
    local done = 0

    -- обход по кругу с курсора: при сотнях очагов каждый всё равно обрабатывается раз в несколько проходов
    if cursor ~= nil and Fires[cursor] == nil then cursor = nil end
    local ent, kind = next(Fires, cursor)
    if ent == nil then ent, kind = next(Fires) end
    while ent ~= nil and done < MAX_FIRES do
        done = done + 1
        cursor = ent
        local nextEnt, nextKind = next(Fires, ent)   -- до обработки: тушение может удалить очаг
        if IsValid(ent) then
            local p = ent:GetPos()
            local key = Spatial.WorldToVoxel(p.x, p.y, p.z)
            if key and not (hasGas and GasAtFire(ent, kind, key, flammable)) and smokeMul > 0 and smokeId > 0 then
                local k = key + Spatial.Z_STRIDE      -- дым — в воксель над очагом
                local amt = FireSize(ent, kind) * smokeMul
                if SmokeAmt[k] then
                    SmokeAmt[k] = SmokeAmt[k] + amt
                else
                    nKeys = nKeys + 1
                    SmokeKeys[nKeys] = k
                    SmokeAmt[k] = amt
                end
            end
        end
        ent, kind = nextEnt, nextKind
        if ent == nil then cursor = nil end
    end

    -- круг обхода закончен (все очаги учтены) — источники дыма по накопленному; центр вокселя над очагом:
    -- соседние языки пламени сливаются в один столб
    if cursor == nil and smokeId > 0 then SyncSmoke(smokeId) end
end)
