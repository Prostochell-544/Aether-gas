-- lua/aether_gas/shared/sh_custom.lua
--[[
    Пользовательские газы (слоты custom_1..custom_4 из sh_registry.lua).

    Клиент (редактор газомёта) шлёт слот + JSON с параметрами → сервер проверяет права
    (AetherGas.CanEditCustomGas), приводит каждое поле к белому списку и диапазону (CustomGasFields),
    перерегистрирует газ (тот же id — сеть и сетка не ломаются), сохраняет в data/aether_custom_gases.json
    и рассылает всем. Новый игрок получает все слоты при AetherGas.ClientReady.

    Хук AetherGas.CustomGasChanged(name, def) — в обоих реалмах после применения.
]]

local AetherGas = AetherGas
local C  = AetherGas.Const
local CV = AetherGas.CVar

-- Поля редактора: ключ, тип, мин, макс, подпись, знаков после запятой. «screen.*» — экранные эффекты.
AetherGas.CustomGasFields = {
    { "printName",        "string", 0, 32, "Name" },
    { "color",            "color",  0, 0,  "Color" },
    { "density",          "num",  0.05, 4,    "Density (air = 1)", 2 },
    { "emitTemp",         "num",  -150, 800,  "Temperature at source, C", 0 },
    { "cooling",          "num",  0,    2,    "Cooling rate, 1/s", 2 },
    { "opacity",          "num",  0,    1.5,  "Opacity", 2 },
    { "fogDistance",      "num",  0,    4000, "Visibility inside the cloud (0 = no fog)", 0 },
    { "blocksVision",     "bool", 0, 1,    "Blocks line of sight (players, NPCs)" },
    { "visionThreshold",  "num",  0.05, 1,    "Concentration that blocks sight", 2 },
    { "diffusion",        "num",  0,    1,    "Diffusion", 2 },
    { "spread",           "num",  0,    1,    "Pressure spread (room filling)", 2 },
    { "cohesion",         "num",  0,    0.8,  "Cohesion (sharp cloud edge)", 2 },
    { "decay",            "num",  0,    1,    "Decay, 1/s", 3 },
    { "muffle",           "num",  0,    1,    "Sound muffling", 2 },
    { "damage",           "num",  0,    100,  "Damage, HP/s at full concentration", 1 },
    { "damageKind",       "enum", 0, 0,    "Damage type" },
    { "damageThreshold",  "num",  0.01, 1,    "No damage below concentration", 2 },
    { "maskProtects",     "bool", 0, 1,    "Gas mask protects" },
    { "skinDamage",       "num",  0,    1,    "Skin damage (mask does not stop this part)", 2 },
    { "slowdown",         "num",  0,    0.9,  "Movement slowdown", 2 },
    { "flammable",        "bool", 0, 1,    "Flammable / explosive" },
    { "flameMin",         "num",  0.01, 1,    "Lower flammable limit", 2 },
    { "flameMax",         "num",  0.01, 1,    "Upper flammable limit", 2 },
    { "blastDamage",      "num",  0,    300,  "Explosion damage per voxel", 0 },
    { "igniteOnBlast",    "bool", 0, 1,    "Explosion sets things on fire" },
    { "extinguishes",     "bool", 0, 1,    "Puts out fire" },
    { "screen.cough",     "num",  0,    2,    "Screen: coughing", 2 },
    { "screen.distortion","num",  0,    1,    "Screen: distortion", 2 },
    { "screen.blur",      "num",  0,    1,    "Screen: tears / blur", 2 },
    { "screen.narrow",    "num",  0,    1,    "Screen: tunnel vision", 2 },
    { "screen.darken",    "num",  0,    1,    "Screen: hypoxia darkening", 2 },
    { "screen.fog",       "num",  0,    1,    "Screen: fogging", 2 },
    { "screen.shake",     "num",  0,    1,    "Screen: convulsions", 2 },
}

AetherGas.DamageKinds = {   -- имя в редакторе → тип урона
    { "toxic", DMG_NERVEGAS }, { "burn", DMG_BURN }, { "asphyxia", DMG_DROWN }, { "acid", DMG_ACID },
}

local function KindOf(dmgType)
    for i = 1, #AetherGas.DamageKinds do
        if AetherGas.DamageKinds[i][2] == dmgType then return AetherGas.DamageKinds[i][1] end
    end
    return "toxic"
end

--- Плоская таблица полей редактора из описания газа (для UI и для JSON).
function AetherGas.CustomGasToFlat(def)
    local out = {}
    for i = 1, #AetherGas.CustomGasFields do
        local f = AetherGas.CustomGasFields[i]
        local key, kind = f[1], f[2]
        if key == "damageKind" then
            out[key] = KindOf(def.damageType)
        elseif kind == "color" then
            out[key] = { r = def.color.r, g = def.color.g, b = def.color.b }
        elseif string.StartWith(key, "screen.") then
            out[key] = def.screen and tonumber(def.screen[string.sub(key, 8)]) or 0
        else
            out[key] = def[key]
        end
    end
    return out
end

--- Белый список + диапазоны: из произвольной (присланной) таблицы — полное описание газа для RegisterGas.
function AetherGas.SanitizeCustomGas(raw, slotIndex)
    raw = istable(raw) and raw or {}
    local def = { custom = true, screen = {}, grenade = { 8, 16, 20 } }
    for i = 1, #AetherGas.CustomGasFields do
        local f = AetherGas.CustomGasFields[i]
        local key, kind, lo, hi = f[1], f[2], f[3], f[4]
        local v = raw[key]
        if kind == "num" then
            v = math.Clamp(tonumber(v) or 0, lo, hi)
            if string.StartWith(key, "screen.") then
                if v > 0 then def.screen[string.sub(key, 8)] = v end
            else
                def[key] = v
            end
        elseif kind == "bool" then
            def[key] = v == true or v == 1 or v == "1" or v == "true"
        elseif kind == "string" then
            v = isstring(v) and string.gsub(v, "[%c\"\\]", "") or ""
            v = string.Trim(string.sub(v, 1, hi))
            def.printName = v ~= "" and v or ("Custom Gas " .. (slotIndex or 1))
        elseif kind == "color" then
            local t = istable(v) and v or {}
            def.color = Color(math.Clamp(tonumber(t.r) or 200, 0, 255), math.Clamp(tonumber(t.g) or 200, 0, 255),
                math.Clamp(tonumber(t.b) or 200, 0, 255))
        elseif key == "damageKind" then
            def.damageType = DMG_NERVEGAS
            for k = 1, #AetherGas.DamageKinds do
                if AetherGas.DamageKinds[k][1] == v then def.damageType = AetherGas.DamageKinds[k][2] end
            end
        end
    end
    if def.flameMax < def.flameMin then def.flameMax = def.flameMin end
    return def
end

local function SlotIndex(name)
    for i = 1, #AetherGas.CustomSlots do
        if AetherGas.CustomSlots[i] == name then return i end
    end
    return nil
end
AetherGas.CustomSlotIndex = SlotIndex

local function Apply(name, def)
    AetherGas.RegisterGas(name, def)
    hook.Run("AetherGas.CustomGasChanged", name, AetherGas.GetGas(name))
end

if CLIENT then
    net.Receive(C.NET_GASDEF, function()
        local n = net.ReadUInt(4)
        for _ = 1, n do
            local name, json = net.ReadString(), net.ReadString()
            local idx = SlotIndex(name)
            if idx then Apply(name, AetherGas.SanitizeCustomGas(util.JSONToTable(json), idx)) end
        end
    end)

    --- Отправить параметры слота на сервер (редактор газомёта). flat — таблица полей CustomGasFields.
    function AetherGas.SubmitCustomGas(name, flat)
        if not SlotIndex(name) then return end
        net.Start(C.NET_GASDEF)
        net.WriteString(name)
        net.WriteString(util.TableToJSON(flat))
        net.SendToServer()
    end
    return
end

---------------------------------------------------------------------------------------------------
-- Сервер
---------------------------------------------------------------------------------------------------
local SAVE_FILE = "aether_custom_gases.json"
AetherGas.CustomStore = AetherGas.CustomStore or {}   -- [слот] = плоская таблица (то, что сохраняется и рассылается)
local Store = AetherGas.CustomStore

--- Кто может менять пользовательские газы. Хук AetherGas.CanEditCustomGas(ply, slot) → true/false
-- переопределяет; по умолчанию — одиночная игра, админы или все при aether_custom_gas_everyone 1.
function AetherGas.CanEditCustomGas(ply, slot)
    local r = hook.Run("AetherGas.CanEditCustomGas", ply, slot)
    if r ~= nil then return r == true end
    return game.SinglePlayer() or ply:IsAdmin() or CV.CustomEveryone:GetBool()
end

local function Broadcast(names, target)
    net.Start(C.NET_GASDEF)
    net.WriteUInt(#names, 4)
    for i = 1, #names do
        net.WriteString(names[i])
        net.WriteString(util.TableToJSON(Store[names[i]]))
    end
    if target then net.Send(target) else net.Broadcast() end
end

--- Серверный API: задать параметры слота (flat — поля CustomGasFields; недостающие = 0/false).
function AetherGas.SetCustomGas(name, flat)
    local idx = SlotIndex(name)
    if not idx then return false end
    local def = AetherGas.SanitizeCustomGas(flat, idx)
    Store[name] = AetherGas.CustomGasToFlat(def)
    Apply(name, def)
    file.Write(SAVE_FILE, util.TableToJSON(Store, true))
    Broadcast({ name })
    return true
end

local nextEdit = setmetatable({}, { __mode = "k" })
net.Receive(C.NET_GASDEF, function(len, ply)
    if not IsValid(ply) or len > 16000 then return end
    if (nextEdit[ply] or 0) > CurTime() then return end
    nextEdit[ply] = CurTime() + 0.5
    local name, json = net.ReadString(), net.ReadString()
    if not SlotIndex(name) then return end
    if not AetherGas.CanEditCustomGas(ply, name) then
        ply:ChatPrint("[Aether] Custom gases can only be edited by admins on this server.")
        return
    end
    AetherGas.SetCustomGas(name, util.JSONToTable(json) or {})
end)

-- Загрузка сохранённых слотов (переживают рестарт сервера)
do
    local saved = file.Exists(SAVE_FILE, "DATA") and util.JSONToTable(file.Read(SAVE_FILE, "DATA") or "") or nil
    if istable(saved) then
        for name, flat in pairs(saved) do
            local idx = SlotIndex(name)
            if idx and istable(flat) then
                local def = AetherGas.SanitizeCustomGas(flat, idx)
                Store[name] = AetherGas.CustomGasToFlat(def)
                Apply(name, def)
            end
        end
    end
end

hook.Add("AetherGas.ClientReady", "AetherGas.Custom", function(ply)
    local names = {}
    for name in pairs(Store) do names[#names + 1] = name end
    if #names > 0 then Broadcast(names, ply) end
end)
