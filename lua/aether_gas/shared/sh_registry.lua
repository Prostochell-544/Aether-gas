-- lua/aether_gas/shared/sh_registry.lua
-- Реестр газов, константы, ConVar'ы и имена сетевых сообщений Aether. Грузится первым в обоих реалмах.

AetherGas = AetherGas or {}
local AetherGas = AetherGas

AetherGas.Version = "0.9.2"

-- Пространства имён модулей. Создаются здесь один раз: модули берут на них ссылки при загрузке, а
-- lua refresh / lua_openscript не теряет накопленное состояние (таблицы переживают повторный include).
AetherGas.Spatial = AetherGas.Spatial or {}
AetherGas.Portals = AetherGas.Portals or {}
AetherGas.Debug   = AetherGas.Debug   or {}

---------------------------------------------------------------------------------------------------
-- 1. Константы
---------------------------------------------------------------------------------------------------
local C = AetherGas.Const or {}
AetherGas.Const = C

-- Сетка: 10 бит на ось глобальной координаты вокселя (раскладка ключа — в sh_spatial.lua).
-- 1024 ячейки × VOXEL_SIZE_MIN (32) = 32768 юнитов = полный диапазон координат Source (±16384).
C.GRID_BITS       = 10
C.GRID_DIM        = 1024
C.GRID_BIAS       = 512
C.CHUNK_SIZE      = 8           -- вокселей на ребро чанка
C.CHUNK_VOLUME    = 512         -- 8³
C.VOXEL_SIZE_MIN  = 32
C.VOXEL_SIZE_MAX  = 128
C.MAX_CHUNKS_HARD = 4096        -- потолок пула: 4096 × 512 = 2 097 152 ячейки на каждое поле SoA

-- Бюджеты трассировки
C.RECALC_TRACES_PER_TICK = 16    -- жёсткий лимит перепроверки порталов (двери/окна), трейсов за тик
C.QUEUE_TIME_GUARD       = 0.002 -- аварийный предел времени разбора любой очереди трейсов, секунды

-- Термодинамика (°C). Поверхности мира считаем «холодными» — равными температуре воздуха.
C.AMBIENT_TEMP = 20
C.KELVIN       = 273.15

C.MAX_GAS_TYPES = 255           -- id газа хранится в 8 битах, 0 = пустая ячейка

-- Сетевые сообщения
C.NET_PORTAL       = "AetherGas.Portal"      -- пакет событий порталов: N × [kind:3][entIndex:13]
C.NET_GRID_RESET   = "AetherGas.GridReset"   -- смена размера вокселя/маски → полный сброс сетки
C.NET_CLIENT_READY = "AetherGas.ClientReady" -- клиент загрузился → сервер досылает текущее состояние
C.NET_SOLVER       = "AetherGas.Solver"      -- события солвера: источники, туннели пуль, взрывы, поджиг
C.NET_SNAPSHOT     = "AetherGas.Snapshot"    -- сжатые снимки чанков (синхронизация облаков)
C.NET_ADMIN_CVAR   = "AetherGas.AdminCVar"   -- меню Q: суперадмин меняет серверные aether_* ConVar'ы
C.NET_MASK         = "AetherGas.Mask"        -- клиент снимает противогаз
C.NET_GASDEF       = "AetherGas.GasDef"      -- параметры пользовательского газа (редактор газомёта ↔ сервер)

if SERVER then
    util.AddNetworkString(C.NET_SNAPSHOT)
    util.AddNetworkString(C.NET_ADMIN_CVAR)
    util.AddNetworkString(C.NET_MASK)
    util.AddNetworkString(C.NET_GASDEF)
    util.AddNetworkString(C.NET_SOLVER)
    util.AddNetworkString(C.NET_PORTAL)
    util.AddNetworkString(C.NET_GRID_RESET)
    util.AddNetworkString(C.NET_CLIENT_READY)
end

---------------------------------------------------------------------------------------------------
-- 2. ConVar'ы
-- Объявляются в shared-коде с FCVAR_REPLICATED: сервер авторитетен, клиент читает то же значение.
---------------------------------------------------------------------------------------------------
local CV = AetherGas.CVar or {}
AetherGas.CVar = CV

local FL_SHARED = bit.bor(FCVAR_ARCHIVE, FCVAR_REPLICATED)
local FL_DEBUG  = FCVAR_REPLICATED

local function Define(key, name, default, flags, help, minValue, maxValue)
    CV[key] = CreateConVar(name, default, flags, help, minValue, maxValue)
end

Define("Enabled",      "aether_enabled",       "1",   FL_SHARED,
    "Aether: enable gas simulation (0/1).", 0, 1)
Define("VoxelSize",    "aether_voxel_size",    "40",  FL_SHARED,
    "Aether: voxel size in Source units (32-128). Changing it resets all gas.",
    C.VOXEL_SIZE_MIN, C.VOXEL_SIZE_MAX)
Define("MaxChunks",    "aether_max_chunks",    "512", FL_SHARED,
    "Aether: maximum active 8x8x8 chunks.", 16, C.MAX_CHUNKS_HARD)
Define("TickBudget",   "aether_tick_budget",   "1.5", FL_SHARED,
    "Aether: solver time budget per tick, ms.", 0.25, 4)
Define("ProbeBudget",  "aether_probe_budget",  "48",  FL_SHARED,
    "Aether: collision baking traces per tick.", 4, 256)
Define("GratesBlock",  "aether_grates_block",  "0",   FL_SHARED,
    "Aether: grates and meshes (CONTENTS_GRATE) block gas (0/1). Changing it resets all gas.", 0, 1)
Define("WindSpeed",    "aether_wind_speed",    "0",   FL_SHARED,
    "Aether: global wind speed, units/s.", 0, 600)
Define("WindYaw",      "aether_wind_yaw",      "0",   FL_SHARED,
    "Aether: wind direction (yaw), degrees.", 0, 360)
Define("WindStormFox", "aether_wind_stormfox", "1",   FL_SHARED,
    "Aether: use StormFox 2 wind when installed (0/1).", 0, 1)
Define("DamageScale",  "aether_damage_scale",  "1",   FL_SHARED,
    "Aether: gas damage multiplier (0 = gases are harmless).", 0, 10)
Define("NPCBlind",     "aether_npc_blind",     "1",   FL_SHARED,
    "Aether: dense smoke blinds NPCs and NextBots (0/1).", 0, 1)
Define("MaskFilter",   "aether_mask_filter",   "240", FL_SHARED,
    "Aether: gas mask filter life, seconds in toxic gas.", 10, 3600)
Define("SyncInterval", "aether_sync_interval", "0.5", FL_SHARED,
    "Aether: how often the server sends one chunk snapshot to clients, s.", 0.1, 10)
Define("CustomEveryone", "aether_custom_gas_everyone", "0", FL_SHARED,
    "Aether: everyone, not only admins, may edit custom gases (0/1).", 0, 1)
Define("GunToxicAdmin", "aether_gasgun_toxic_admin", "0", FL_SHARED,
    "Aether: only admins may spray toxic or flammable gases (0/1).", 0, 1)
Define("TunnelStrength", "aether_tunnel_strength", "0.85", FL_SHARED,
    "Aether: how much gas a bullet knocks out along its path (0 = bullets do not cut smoke, 1 = clean tunnel).", 0, 1)
Define("FireSmoke",    "aether_fire_smoke",    "1",   FL_SHARED,
    "Aether: smoke from fire multiplier (vFire, env_fire, burning props); 0 = fire makes no smoke.", 0, 5)
Define("FireVFire",    "aether_fire_vfire",    "1",   FL_SHARED,
    "Aether: gas explosions spread vFire fire when vFire is installed (0/1).", 0, 1)
Define("VFireWind",    "aether_vfire_wind",    "1",   FL_SHARED,
    "Aether: vFire flames lean with Aether wind (0 = vFire keeps its own wind).", 0, 1)
Define("DebugGrid",    "aether_debug_grid",    "0",   FL_DEBUG,
    "Aether: grid debug overlay (needs developer 1). " ..
    "0 off, 1 closed faces/chunks/queues/bindings, 2 also open faces and cells inside walls.", 0, 2)
Define("DebugRadius",  "aether_debug_radius",  "640", FL_DEBUG,
    "Aether: aether_debug_grid draw radius, units.", 128, 4096)

---------------------------------------------------------------------------------------------------
-- 3. Реестр газов
--
-- Плавучесть считается солвером из плотности и температуры (идеальный газ при постоянном давлении):
--     ρ_eff(T) = density · T_amb / T          (T в кельвинах)
--     a_up     = g_eff · (1 − ρ_eff(T))       (> 0 — всплывает, < 0 — стелется)
-- Поэтому co_smoke (0.95) при 320 °C даёт ρ_eff ≈ 0.48 и рвётся к потолку, а остыв до 20 °C
-- становится чуть тяжелее воздуха и заполняет помещение сверху вниз.
---------------------------------------------------------------------------------------------------
AetherGas.Gases    = AetherGas.Gases    or {}  -- [name] = def
AetherGas.GasById  = AetherGas.GasById  or {}  -- [id]   = def
AetherGas.GasCount = AetherGas.GasCount or 0

-- SoA-параметры по id газа: горячие циклы солвера читают P.Density[id] без разыменования def.
local P = AetherGas.GasParams or {}
AetherGas.GasParams = P

local PARAM_FIELDS = {
    "Density", "Diffusion", "Spread", "Cohesion", "Decay", "EmitTemp", "Cooling", "Opacity", "VisionThreshold",
    "Muffle", "Damage", "DamageThreshold", "Slowdown", "FlameMin", "FlameMax", "BlastDamage",
    "CondenseRate", "CondenseTemp", "IndoorDecay",
}
for i = 1, #PARAM_FIELDS do
    local name = PARAM_FIELDS[i]
    P[name] = P[name] or {}
end

-- Значения, которые не достигаются никогда (порог видимости/воспламенения для «пустой» ячейки)
local NEVER_HIGH, NEVER_LOW = 2, -1

-- id 0 — пустая ячейка: нейтральные значения, чтобы солвер читал P.X[gasId] без ветвлений.
P.Density[0], P.Diffusion[0], P.Spread[0], P.Decay[0], P.Cohesion[0] = 1, 0, 0, 0, 0
P.EmitTemp[0], P.Cooling[0], P.Opacity[0], P.VisionThreshold[0] = C.AMBIENT_TEMP, 0, 0, NEVER_HIGH
P.Muffle[0], P.Damage[0], P.DamageThreshold[0], P.Slowdown[0] = 0, 0, NEVER_HIGH, 0
P.FlameMin[0], P.FlameMax[0], P.BlastDamage[0] = NEVER_HIGH, NEVER_LOW, 0
P.CondenseRate[0], P.CondenseTemp[0], P.IndoorDecay[0] = 0, NEVER_LOW, 1

local DEFAULTS = {
    printName       = "Gas",
    density         = 1.0,               -- относительно воздуха при 20 °C
    diffusion       = 0.15,              -- доля обмена с каждым открытым соседом, 1/с
    spread          = 0.5,               -- сила выравнивания давления (flood fill), 0..1
    cohesion        = 0,                 -- ниже этой концентрации ячейка газ дальше не расталкивает:
                                         -- облако держит объём ≈ масса / cohesion с чёткой границей
    decay           = 0.01,              -- экспоненциальная диссипация под открытым небом, 1/с
    indoorDecay     = 0.1,               -- множитель decay в помещении: газ в закрытой комнате почти не
                                         -- исчезает, а разбавляется (1 — пар/азот: конденсация, испарение)
    emitTemp        = C.AMBIENT_TEMP,    -- температура на выходе источника, °C
    cooling         = 0.05,              -- релаксация температуры к окружающей, 1/с
    color           = Color(200, 200, 200),
    opacity         = 0.5,               -- визуальная экстинкция на воксель при концентрации 1.0
    blocksVision    = false,             -- перекрывает линию взгляда игрокам и NPC/NextBot
    visionThreshold = 0.35,              -- концентрация, с которой blocksVision срабатывает
    muffle          = 0,                 -- 0..1, глушение звуков внутри облака
    damage          = 0,                 -- HP/с при концентрации 1.0
    damageType      = DMG_GENERIC,
    damageThreshold = 0.1,               -- ниже этой концентрации урона нет
    maskProtects    = true,              -- противогаз защищает
    slowdown        = 0,                 -- 0..1, замедление движения при концентрации 1.0
    flammable       = false,
    flameMin        = 0.05,              -- нижний концентрационный предел воспламенения
    flameMax        = 1.0,               -- верхний предел (выше — смесь слишком богатая)
    blastDamage     = 0,                 -- урон взрыва одного вокселя при концентрации 1.0
    igniteOnBlast   = false,             -- детонация поджигает сущности в зоне
    condenses       = false,
    condenseRate    = 0,                 -- доля, оседающая у холодных стен за секунду
    condenseTemp    = 60,                -- ниже этой температуры газа конденсация идёт активно, °C
    fogDistance     = 0,                 -- дальность видимости изнутри облака при c = 1, юниты (0 — туман не нужен)
    skinDamage      = 0,                 -- доля урона, которую противогаз не снимает (кожное действие);
                                         -- защищает только костюм (GBombs hazsuit / хук AetherGas.HasGasSuit)
    grenade         = { 8, 16, 30 },     -- граната: концентрация/с, длительность с, скорость струи вверх
}

local function Num(value, fallback, lo, hi)
    value = tonumber(value) or fallback
    if value < lo then return lo end
    if value > hi then return hi end
    return value
end

local function CompileParams(g)
    local id = g.id
    P.Density[id]         = g.density
    P.Diffusion[id]       = g.diffusion
    P.Spread[id]          = g.spread
    P.Cohesion[id]        = g.cohesion
    P.Decay[id]           = g.decay
    P.EmitTemp[id]        = g.emitTemp
    P.Cooling[id]         = g.cooling
    P.Opacity[id]         = g.opacity
    P.VisionThreshold[id] = g.blocksVision and g.visionThreshold or NEVER_HIGH
    P.Muffle[id]          = g.muffle
    P.Damage[id]          = g.damage
    P.DamageThreshold[id] = g.damage > 0 and g.damageThreshold or NEVER_HIGH
    P.Slowdown[id]        = g.slowdown
    P.FlameMin[id]        = g.flammable and g.flameMin or NEVER_HIGH
    P.FlameMax[id]        = g.flammable and g.flameMax or NEVER_LOW
    P.BlastDamage[id]     = g.flammable and g.blastDamage or 0
    P.CondenseRate[id]    = g.condenses and g.condenseRate or 0
    P.CondenseTemp[id]    = g.condenses and g.condenseTemp or NEVER_LOW
    P.IndoorDecay[id]     = g.indoorDecay
end

local function RebuildChecksum()
    local names = {}
    for id = 1, AetherGas.GasCount do names[id] = AetherGas.GasById[id].name end
    -- Сверка реестров сервера и клиента: id газа уходит в сеть, порядок регистрации обязан совпадать.
    AetherGas.RegistryChecksum = util.CRC(table.concat(names, ";"))
end

--- Регистрирует (или обновляет при lua refresh) тип газа.
-- Вызывать только из shared-кода и в одинаковом порядке на сервере и клиенте: id — порядковый номер.
-- @param name string  [a-z0-9_]+
-- @param def  table   поля из DEFAULTS; неуказанные берутся по умолчанию
-- @return number id газа (1..255)
function AetherGas.RegisterGas(name, def)
    assert(isstring(name) and string.match(name, "^[%l%d_]+$") ~= nil,
        "[Aether] RegisterGas: gas name must match [a-z0-9_]+")
    assert(istable(def), "[Aether] RegisterGas: gas definition must be a table")

    local existing = AetherGas.Gases[name]
    local id
    if existing then
        id = existing.id
    else
        assert(AetherGas.GasCount < C.MAX_GAS_TYPES, "[Aether] RegisterGas: the 255 gas limit is reached")
        id = AetherGas.GasCount + 1
        AetherGas.GasCount = id
    end

    -- Копия: чужие таблицы описаний не мутируем, DEFAULTS тоже.
    local g = {}
    for k, v in pairs(DEFAULTS) do g[k] = v end
    for k, v in pairs(def) do g[k] = v end
    g.id, g.name = id, name

    g.printName       = tostring(g.printName)
    g.density         = Num(g.density, 1, 0.05, 10)
    g.diffusion       = Num(g.diffusion, 0.15, 0, 1)
    g.spread          = Num(g.spread, 0.5, 0, 1)
    g.cohesion        = Num(g.cohesion, 0, 0, 1)
    g.decay           = Num(g.decay, 0.01, 0, 10)
    g.indoorDecay     = Num(g.indoorDecay, 0.1, 0, 1)
    g.emitTemp        = Num(g.emitTemp, C.AMBIENT_TEMP, -100, 2000)
    g.cooling         = Num(g.cooling, 0.05, 0, 10)
    g.opacity         = Num(g.opacity, 0.5, 0, 4)
    g.visionThreshold = Num(g.visionThreshold, 0.35, 0, 1)
    g.muffle          = Num(g.muffle, 0, 0, 1)
    g.damage          = Num(g.damage, 0, 0, 1000)
    g.damageType      = math.floor(tonumber(g.damageType) or DMG_GENERIC)
    g.damageThreshold = Num(g.damageThreshold, 0.1, 0, 1)
    g.slowdown        = Num(g.slowdown, 0, 0, 1)
    g.flameMin        = Num(g.flameMin, 0.05, 0, 1)
    g.flameMax        = Num(g.flameMax, 1, g.flameMin, 1)
    g.blastDamage     = Num(g.blastDamage, 0, 0, 10000)
    g.condenseRate    = Num(g.condenseRate, 0, 0, 10)
    g.condenseTemp    = Num(g.condenseTemp, 60, -100, 2000)
    g.fogDistance     = Num(g.fogDistance, 0, 0, 20000)
    g.skinDamage      = Num(g.skinDamage, 0, 0, 1)
    if not istable(g.grenade) then g.grenade = DEFAULTS.grenade end
    g.blocksVision    = g.blocksVision == true
    g.maskProtects    = g.maskProtects == true
    g.flammable       = g.flammable == true
    g.igniteOnBlast   = g.igniteOnBlast == true
    g.condenses       = g.condenses == true
    if not IsColor(g.color) then g.color = DEFAULTS.color end

    AetherGas.Gases[name] = g
    AetherGas.GasById[id] = g
    CompileParams(g)
    RebuildChecksum()

    hook.Run("AetherGas.GasRegistered", g)
    return id
end

function AetherGas.GetGas(nameOrId)
    if isnumber(nameOrId) then return AetherGas.GasById[nameOrId] end
    return AetherGas.Gases[nameOrId]
end

function AetherGas.GetGasId(name)
    local g = AetherGas.Gases[name]
    return g and g.id or 0
end

-- Газы аддона в порядке регистрации = скины моделей гранаты и баллона (tools/make_models.py GAS_ORDER).
AetherGas.BaseGases = {
    "smoke", "chlorine", "methane", "co_smoke", "steam",
    "tear_gas", "sarin", "mustard", "h2s", "ammonia", "hydrogen", "nitrogen", "co2",
    "signal_red", "signal_green", "signal_yellow", "signal_violet", "signal_orange",
}

-- Баллон «старый, без надписей» (для машиним и сцен): последний скин модели баллона, после газов.
AetherGas.PLAIN_CYLINDER_SKIN = #AetherGas.BaseGases

--- Скин моделей Aether (граната, баллон) под газ: базовые газы → скины 0..17, сторонние → 0.
function AetherGas.GasSkin(name)
    local g = AetherGas.Gases[name]
    if not g or g.id > #AetherGas.BaseGases then return 0 end
    return g.id - 1
end

--- Относительная плотность газа при температуре tempC (идеальный газ, см. шапку раздела).
function AetherGas.EffectiveDensity(id, tempC)
    local tK = tempC + C.KELVIN
    if tK < 1 then tK = 1 end
    return P.Density[id] * (C.AMBIENT_TEMP + C.KELVIN) / tK
end

---------------------------------------------------------------------------------------------------
-- 4. Базовые газы. Порядок регистрации = id = AetherGas.BaseGases (скины моделей).
-- fogDistance — видимость изнутри облака при c = 1 (туман движка в cl_mesher), grenade — профиль гранаты.
---------------------------------------------------------------------------------------------------

-- Тактический дым: нейтральная плавучесть, сильное выравнивание давления — заполняет помещение
-- целиком (flood fill), полностью перекрывает обзор и глушит звук.
AetherGas.RegisterGas("smoke", {
    printName = "Tactical Smoke",
    density = 1.0, diffusion = 0.22, spread = 0.85, cohesion = 0.45, decay = 0.015,
    emitTemp = 30, cooling = 0.25,
    color = Color(196, 198, 204), opacity = 1.0,
    blocksVision = true, visionThreshold = 0.25,
    muffle = 0.45, fogDistance = 150,
    grenade = { 9, 18, 40 },
    screen = {},
})

-- Хлор: тяжелее воздуха — стелется, стекает по лестницам, копится в низинах.
-- DMG_NERVEGAS, а не DMG_POISON: у игроков HL2 урон DMG_POISON постепенно восстанавливается.
AetherGas.RegisterGas("chlorine", {
    printName = "Chlorine",
    density = 1.8, diffusion = 0.10, spread = 0.35, cohesion = 0.05, decay = 0.006,
    emitTemp = 15, cooling = 0.1,
    color = Color(196, 206, 62), opacity = 0.9,
    muffle = 0.05, fogDistance = 420,
    damage = 7, damageType = DMG_NERVEGAS, damageThreshold = 0.08, maskProtects = true,
    slowdown = 0.1,
    grenade = { 6, 20, 0 },
    screen = { cough = 1.0, distortion = 0.5, tint = Color(190, 210, 90) },
})

-- Метан: всплывает к потолку и в вентиляцию; сам по себе невидим (лёгкое марево).
-- Концентрационное окно 0.05–0.9: слишком богатая смесь у самого источника не горит,
-- поэтому детонация начинается с краёв облака и цепочкой уходит внутрь.
AetherGas.RegisterGas("methane", {
    printName = "Methane",
    density = 0.55, diffusion = 0.20, spread = 0.5, decay = 0.003,
    color = Color(170, 190, 230), opacity = 0.012,
    flammable = true, flameMin = 0.05, flameMax = 0.9, blastDamage = 110, igniteOnBlast = true,
    grenade = { 7, 15, 0 },
    screen = { distortion = 0.15 },
})

-- Едкий дым пожара с CO: горячим уходит под потолок, остывая — заполняет помещение сверху вниз.
-- Обычный фильтр противогаза угарный газ не задерживает (нужен гопкалитовый патрон).
AetherGas.RegisterGas("co_smoke", {
    printName = "Fire Smoke (CO)",
    density = 0.95, diffusion = 0.16, spread = 0.55, cohesion = 0.1, decay = 0.004,
    emitTemp = 320, cooling = 0.035,
    color = Color(42, 40, 38), opacity = 0.9,
    blocksVision = true, visionThreshold = 0.45,
    muffle = 0.2, fogDistance = 230,
    damage = 4, damageType = DMG_DROWN, damageThreshold = 0.2, maskProtects = false,
    slowdown = 0.35,
    grenade = { 7, 20, 60 },
    screen = { darken = 0.8, cough = 0.5 },
})

-- Горячий пар: быстро поднимается и конденсируется у холодных поверхностей.
AetherGas.RegisterGas("steam", {
    printName = "Steam",
    density = 0.65, diffusion = 0.25, spread = 0.45, decay = 0.05,
    emitTemp = 100, cooling = 0.12,
    color = Color(236, 238, 242), opacity = 0.55,
    blocksVision = true, visionThreshold = 0.55,
    muffle = 0.1, fogDistance = 260,
    damage = 9, damageType = DMG_BURN, damageThreshold = 0.45, maskProtects = false,
    indoorDecay = 1,
    condenses = true, condenseRate = 0.6, condenseTemp = 60,
    grenade = { 12, 10, 120 },
    screen = { fog = 1.0 },
})

-- Слезоточивый газ CS: аэрозоль чуть тяжелее воздуха. Почти не ранит, но слёзы, кашель и «плывущая»
-- картинка; противогаз защищает полностью.
AetherGas.RegisterGas("tear_gas", {
    printName = "Tear Gas (CS)",
    density = 1.15, diffusion = 0.18, spread = 0.6, cohesion = 0.2, decay = 0.012,
    emitTemp = 40, cooling = 0.2,
    color = Color(226, 228, 214), opacity = 0.6,
    blocksVision = true, visionThreshold = 0.5,
    fogDistance = 380,
    damage = 0.8, damageType = DMG_NERVEGAS, damageThreshold = 0.05, maskProtects = true,
    slowdown = 0.15,
    grenade = { 9, 16, 30 },
    screen = { cough = 1.6, blur = 1.0, tint = Color(235, 225, 200) },
})

-- Зарин (GB): тяжелее воздуха, бесцветен. Смертелен в малой дозе; часть урона идёт через кожу —
-- противогаз снимает только 70 % (полная защита — костюм). Сужение зрачков и судороги.
AetherGas.RegisterGas("sarin", {
    printName = "Sarin (GB)",
    density = 1.4, diffusion = 0.14, spread = 0.4, cohesion = 0.02, decay = 0.008,
    color = Color(210, 220, 228), opacity = 0.015,
    damage = 26, damageType = DMG_NERVEGAS, damageThreshold = 0.02, maskProtects = true, skinDamage = 0.3,
    slowdown = 0.25,
    grenade = { 5, 14, 0 },
    screen = { narrow = 1.0, shake = 1.0, cough = 0.3 },
})

-- Иприт (HD): тяжёлый, очень стойкий — долго держится в низинах бурой дымкой у земли.
-- Нарывное действие через кожу: противогаз снимает только половину урона.
AetherGas.RegisterGas("mustard", {
    printName = "Mustard Gas (HD)",
    density = 1.7, diffusion = 0.06, spread = 0.25, cohesion = 0.06, decay = 0.0015,
    color = Color(150, 124, 62), opacity = 0.35,
    fogDistance = 700,
    damage = 3, damageType = DMG_ACID, damageThreshold = 0.04, maskProtects = true, skinDamage = 0.5,
    grenade = { 5, 18, 0 },
    screen = { cough = 0.4, tint = Color(170, 140, 70), blur = 0.3 },
})

-- Сероводород: чуть тяжелее воздуха, копится в подвалах и коллекторах. Смертелен и горюч.
AetherGas.RegisterGas("h2s", {
    printName = "Hydrogen Sulfide",
    density = 1.19, diffusion = 0.15, spread = 0.45, decay = 0.006,
    color = Color(196, 204, 150), opacity = 0.04,
    damage = 12, damageType = DMG_NERVEGAS, damageThreshold = 0.06, maskProtects = true,
    flammable = true, flameMin = 0.12, flameMax = 0.8, blastDamage = 60, igniteOnBlast = true,
    grenade = { 6, 16, 0 },
    screen = { cough = 0.6, distortion = 0.2, narrow = 0.4 },
})

-- Аммиак: легче воздуха, едкий; на влажном воздухе — белёсое облако. Режет глаза.
AetherGas.RegisterGas("ammonia", {
    printName = "Ammonia",
    density = 0.6, diffusion = 0.2, spread = 0.5, cohesion = 0.08, decay = 0.012,
    emitTemp = -33, cooling = 0.08,   -- выброс сжиженного аммиака холодный: сначала стелется, прогреваясь — всплывает
    color = Color(226, 230, 222), opacity = 0.2,
    fogDistance = 900,
    damage = 3.5, damageType = DMG_ACID, damageThreshold = 0.08, maskProtects = true,
    grenade = { 8, 16, 20 },
    screen = { cough = 0.9, blur = 0.6, tint = Color(220, 230, 235) },
})

-- Водород: самый лёгкий газ — мгновенно уходит вверх; невидим, взрывается сильнее метана.
AetherGas.RegisterGas("hydrogen", {
    printName = "Hydrogen",
    density = 0.07, diffusion = 0.35, spread = 0.5, decay = 0.006,
    color = Color(220, 230, 255), opacity = 0,
    flammable = true, flameMin = 0.04, flameMax = 0.75, blastDamage = 180, igniteOnBlast = true,
    grenade = { 8, 12, 0 },
    screen = {},
})

-- Азотный туман (испарения жидкого азота): ледяной, поэтому очень тяжёлый — стелется по полу белой
-- пеленой; нагреваясь, быстро исчезает. Вытесняет кислород (удушье), замедляет.
AetherGas.RegisterGas("nitrogen", {
    printName = "Cryogenic Nitrogen Fog",
    density = 0.97, diffusion = 0.12, spread = 0.5, cohesion = 0.12, decay = 0.07,
    emitTemp = -150, cooling = 0.12,
    color = Color(238, 244, 250), opacity = 0.8,
    blocksVision = true, visionThreshold = 0.5,
    fogDistance = 300,
    damage = 2, damageType = DMG_DROWN, damageThreshold = 0.5, maskProtects = false,
    slowdown = 0.4, indoorDecay = 1,
    grenade = { 12, 12, 0 },
    extinguishes = true,   -- пламя внутри облака тухнет
    screen = { fog = 0.6, darken = 0.2 },
})

-- Углекислый газ: тяжёлый, бесцветный, удушающий в закрытых объёмах. Гасит огонь (sh_solver: пламя
-- в облаке CO2/азота тухнет).
AetherGas.RegisterGas("co2", {
    printName = "Carbon Dioxide",
    density = 1.52, diffusion = 0.12, spread = 0.45, decay = 0.005,
    emitTemp = 0, cooling = 0.1,
    color = Color(225, 228, 232), opacity = 0.02,
    damage = 2.5, damageType = DMG_DROWN, damageThreshold = 0.35, maskProtects = false,
    slowdown = 0.1,
    grenade = { 9, 14, 0 },
    extinguishes = true,   -- пламя внутри облака тухнет
    screen = { darken = 0.6 },
})

-- Цветные сигнальные дымы: безвредные, плотные — для меток и посадок. Едва тёплые и без струи вверх:
-- облако стелется у шашки и сносится ветром, а не улетает в небо.
local SIGNALS = {
    { "signal_red",    "Signal Smoke (Red)",    Color(214, 52, 44) },
    { "signal_green",  "Signal Smoke (Green)",  Color(60, 176, 72) },
    { "signal_yellow", "Signal Smoke (Yellow)", Color(236, 206, 52) },
    { "signal_violet", "Signal Smoke (Violet)", Color(140, 72, 196) },
    { "signal_orange", "Signal Smoke (Orange)", Color(240, 128, 36) },
}
for i = 1, #SIGNALS do
    local s = SIGNALS[i]
    AetherGas.RegisterGas(s[1], {
        printName = s[2],
        density = 1.0, diffusion = 0.2, spread = 0.7, cohesion = 0.3, decay = 0.02,
        emitTemp = 32, cooling = 0.3,
        color = s[3], opacity = 0.9,
        blocksVision = true, visionThreshold = 0.3,
        muffle = 0.2, fogDistance = 200,
        grenade = { 9, 25, 10 },
        screen = {},
    })
end

-- Пользовательские газы: 4 слота с нейтральными параметрами. Игроки настраивают их в редакторе газомёта
-- (ПКМ), сервер проверяет и рассылает параметры (sh_custom.lua). Id слотов фиксированы — сеть не ломается.
AetherGas.CustomSlots = { "custom_1", "custom_2", "custom_3", "custom_4" }
local CUSTOM_COLORS = { Color(110, 210, 255), Color(255, 110, 200), Color(160, 255, 110), Color(255, 205, 110) }
for i = 1, #AetherGas.CustomSlots do
    AetherGas.RegisterGas(AetherGas.CustomSlots[i], {
        printName = "Custom Gas " .. i, custom = true,
        density = 1.0, diffusion = 0.2, spread = 0.6, cohesion = 0.2, decay = 0.015,
        emitTemp = 25, cooling = 0.2,
        color = CUSTOM_COLORS[i], opacity = 0.8,
        blocksVision = true, visionThreshold = 0.35, fogDistance = 250,
        grenade = { 8, 16, 20 },
        screen = {},
    })
end

-- Точка расширения для сторонних аддонов (вызывать RegisterGas только из shared-кода).
hook.Run("AetherGas.RegisterGases", AetherGas.RegisterGas)
