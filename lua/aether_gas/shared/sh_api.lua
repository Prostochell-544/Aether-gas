-- lua/aether_gas/shared/sh_api.lua
--[[
    Публичное API Aether для других модов: AetherGas.API.*  (стабильный фасад; внутренние модули
    Solver/Spatial могут меняться между версиями, эти функции — нет). Документация: docs/API.md.

    Проверка наличия:   if AetherGas and AetherGas.API and AetherGas.API.Version >= 1 then ... end
    Газы задаются по имени ("chlorine") или id. Позиции — Vector в мировых координатах.

    Сервер: Emit, Puff, Vacuum, Stop, Sink, Push, Blast, Ignite, Clear, GiveMask, RemoveMask, SetCustomGas
    Оба:    RegisterGas, GetGas, GetGases, Sample, IsLineObscured, HasMask
]]

local AetherGas = AetherGas
AetherGas.API = AetherGas.API or {}
local API = AetherGas.API

API.Version = 1

local function Solver() return AetherGas.Solver end

---------------------------------------------------------------------------------------------------
-- Реестр (оба реалма)
---------------------------------------------------------------------------------------------------
--- Регистрирует газ. Вызывать из shared-кода в одинаковом порядке на сервере и клиенте — лучше всего
-- из хука AetherGas.RegisterGases (срабатывает после газов Aether). Возвращает id.
function API.RegisterGas(name, def) return AetherGas.RegisterGas(name, def) end

--- Описание газа (таблица, только чтение) или nil.
function API.GetGas(nameOrId) return AetherGas.GetGas(nameOrId) end

--- Список имён всех газов в порядке id.
function API.GetGases()
    local out = {}
    for id = 1, AetherGas.GasCount do out[id] = AetherGas.GasById[id].name end
    return out
end

---------------------------------------------------------------------------------------------------
-- Запросы к облаку (оба реалма: клиент читает свою копию симуляции)
---------------------------------------------------------------------------------------------------
--- Газ в точке: имя (или nil), концентрация 0..1, температура °C.
function API.Sample(pos)
    local id, c, t = Solver().Sample(pos.x, pos.y, pos.z)
    if id == 0 then return nil, 0, t end
    return AetherGas.GasById[id].name, c, t
end

--- true, если дым между точками перекрывает обзор (как для NPC).
function API.IsLineObscured(a, b)
    return Solver().OpticalDepth(a.x, a.y, a.z, b.x, b.y, b.z, 1.2) >= 1.2
end

--- Надет ли противогаз Aether (NW2, читается и на клиенте).
function API.HasMask(ply) return IsValid(ply) and ply:GetNW2Bool("AetherMask", false) end

if CLIENT then return end

---------------------------------------------------------------------------------------------------
-- Сервер: источники и воздействия (всё реплицируется клиентам событиями)
---------------------------------------------------------------------------------------------------
--- Непрерывный источник. opts (все необязательны):
--   duration — секунд (0/nil — бессрочно, до API.Stop), temp — °C (по умолчанию газа),
--   vel — Vector струи (юнит/с), ent — сущность-носитель (тогда pos и vel в её локальных координатах;
--   источник умирает вместе с ней). rate — концентрации в секунду (6 ≈ граната).
-- Возвращает id источника или nil.
function API.Emit(gas, pos, rate, opts)
    opts = opts or {}
    return Solver().AddSource(gas, pos, rate, opts.duration or 0, opts.temp, opts.vel, opts.ent)
end

--- Разовое облачко: amount концентрации в шар радиуса radius вокселей (0..3). opts: temp, vel.
function API.Puff(gas, pos, amount, radius, opts)
    opts = opts or {}
    Solver().PuffAt(gas, pos, amount, opts.temp, opts.vel, radius)
end

--- Убрать любой газ в шаре радиуса radius вокселей (0..3).
function API.Vacuum(pos, radius) Solver().PuffAt(nil, pos, 0, nil, nil, radius) end

--- Остановить источник/сток по id.
function API.Stop(id) Solver().StopSource(id) end

--- Сток (вытяжка): убирает rate концентрации/с в шаре radius (юниты). duration и ent — как у Emit.
function API.Sink(pos, radius, rate, duration, ent) return Solver().AddSink(pos, radius, rate, duration or 0, ent) end

--- Поток вдоль отрезка a→b (вентилятор, огнетушитель): импульс strength, разбавление dilute 0..1.
function API.Push(a, b, radius, strength, dilute) Solver().PushRayAt(a, b, radius, strength, dilute or 0) end

--- Ударная волна: разгоняет газ; noIgnite = false/nil — поджигает горючий газ в радиусе.
function API.Blast(pos, radius, strength, noIgnite) Solver().BlastAt(pos, radius, strength, noIgnite) end

--- Поджечь газ в точке (если он горюч и концентрация в пределах воспламенения — цепная детонация).
-- (Слабый «взрыв» радиуса 64 с поджигом: точка поджига реплицируется клиентам тем же событием.)
function API.Ignite(pos) Solver().BlastAt(pos, 64, 1, false) end

--- Удалить весь газ и все источники.
function API.Clear() Solver().Clear() end

--- Противогаз Aether: выдать (filter — секунд фильтра), снять (drop = выбросить на землю).
function API.GiveMask(ply, filter) return AetherGas.GiveMask(ply, filter) end
function API.RemoveMask(ply, drop) AetherGas.RemoveMask(ply, drop) end

--- Защита дыхания вашего мода: fn(ply) → 0..1 (или true). Урон Aether × (1 − защита).
function API.RegisterMaskProvider(name, fn) AetherGas.RegisterMaskProvider(name, fn) end

--- Накопленная доза газа в организме (эквивалент концентрации) и снятие заражения кожи.
function API.GetDose(ent, gas) return AetherGas.GetDose and AetherGas.GetDose(ent, gas) or 0 end
function API.Decontaminate(ent) if AetherGas.Decontaminate then AetherGas.Decontaminate(ent) end end
--- Применить антидот («atropine», «decon», «eyewash», «oxygen» или свой из RegisterAntidote). true — подействовал.
function API.ApplyAntidote(ent, kind) return AetherGas.ApplyAntidote and AetherGas.ApplyAntidote(ent, kind) or false end
--- Свой антидот (сервер): { gases = {…}, remove, clearance, harm, duration, decon, prophylaxis, sound }.
function API.RegisterAntidote(kind, def) if AetherGas.RegisterAntidote then AetherGas.RegisterAntidote(kind, def) end end

--- Включить/выключить устройство Aether (баллон, эмиттер, вентилятор, решётку).
function API.SetDeviceOn(ent, on) if AetherGas.SetDeviceOn then AetherGas.SetDeviceOn(ent, on) end end

--- Задать пользовательский газ (слоты "custom_1".."custom_4"): flat — поля AetherGas.CustomGasFields.
function API.SetCustomGas(slot, flat) return AetherGas.SetCustomGas(slot, flat) end
