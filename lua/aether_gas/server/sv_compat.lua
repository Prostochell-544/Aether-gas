-- lua/aether_gas/server/sv_compat.lua
--[[
    Совместимость с популярными модами. Каждая интеграция защитная: если мода нет или его внутреннее
    поле/функция называется иначе, проверка просто возвращает false — ничего не ломается.

    • Противогазы: реестр поставщиков защиты AetherGas.MaskProviders. Встроены: GMod Bombs 5
      (ply.gasmasked / ply.hazsuited), JMod (EZarmor.effects.gasMask), Contagion Gas Mask и общий хук
          hook.Add("AetherGas.HasGasMask", "my_addon", function(ply) return ply.MyMaskOn end)
      Чужая маска защищает так же, как своя (кроме газов с maskProtects = false), фильтр Aether не тратит.
    • vFire: его огонь (класс vfire) поджигает горючий газ — в sh_solver (таймер огня).
    • Вертолёты WAC (wac_hc_base) и LVS (lvs_base_helicopter): поток от винта разгоняет облака.
    • Огнетушитель Robotboy655 (weapon_extinguisher*): струя толкает и разбавляет газ.
    • Procedural Wall Destruction: пробитая стена перепроверяется (sv_portals.lua, класс proceduralwall).
    • Взрывы любых модов (C4, JMod, GBombs…) ловятся по DMG_BLAST — в sh_solver.
    • aether_compat_report — что из этого обнаружено на сервере.
]]

local AetherGas = AetherGas
local Solver    = AetherGas.Solver
local Spatial   = AetherGas.Spatial

---------------------------------------------------------------------------------------------------
-- Противогазы других модов
---------------------------------------------------------------------------------------------------
AetherGas.MaskProviders = AetherGas.MaskProviders or {}
local Providers = AetherGas.MaskProviders

--- Регистрирует поставщика защиты дыхания. fn(ply, gasDef) → доля защиты 0..1 (true = 1, false/nil = 0).
-- opts.passDamage = true: урон газа всё равно наносится (тип DMG_* из реестра), чтобы маска мода сама
-- перехватила его в EntityTakeDamage и потратила свой фильтр; Aether при этом не кашляет и гасит эффекты.
function AetherGas.RegisterMaskProvider(name, fn, opts)
    for i = 1, #Providers do
        if Providers[i].name == name then Providers[i].fn, Providers[i].opts = fn, opts return end
    end
    Providers[#Providers + 1] = { name = name, fn = fn, opts = opts }
end

-- Working "Rebirth" Gas Mask (& Base) by Hidden (Workshop 3337361530; сверено с кодом
-- sv_gasmaskeffects.lua / weapon_bo1_gasmask.lua). Надетая маска: NW «GasMaskIsOn», типы урона
-- NW «GasMaskDamageTypes», ply.gasmasked — фильтр не пуст, прочность NW «GasMaskHealth» при
-- NW «GasMaskCanBreak». Мод сам блокирует такой урон в EntityTakeDamage и тратит фильтр на его величину —
-- поэтому passDamage: Aether наносит урон своего типа, а маска Rebirth его поглощает.
AetherGas.RegisterMaskProvider("rebirth", function(ply, def)
    if not ply:GetNW2Bool("GasMaskIsOn", false) and not ply:GetNWBool("GasMaskIsOn", false) then return 0 end
    if ply.gasmasked ~= true then return 0 end                         -- фильтр кончился
    if ply:GetNWBool("GasMaskCanBreak", false) and ply:GetNWInt("GasMaskHealth", 0) <= 0 then return 0 end
    local types = ply:GetNWInt("GasMaskDamageTypes", 0)
    if def and bit.band(def.damageType, bit.bnot(types)) ~= 0 then return 0 end   -- тип урона газа не фильтруется
    return 1
end, { passDamage = true })

-- GMod Bombs 5 (сверено с кодом: gas_mask.lua / hazmat_suit.lua ставят эти поля на сервере).
-- Флаг, который выставляет наша же маска (связь в обратную сторону), не считаем чужой маской.
AetherGas.RegisterMaskProvider("gbombs5", function(ply)
    if ply.AetherSetGBMask then return ply.hazsuited == true end
    -- маска Rebirth тоже ставит gasmasked (совместимость с GBombs) — её считает поставщик «rebirth»
    if ply:GetNWBool("GasMaskIsOn", false) then return ply.hazsuited == true end
    return ply.gasmasked == true or ply.hazsuited == true
end)

-- JMod (сверено с кодом: газы JMod спрашивают JMod.GetArmorBiologicalResistance(ply, DMG_NERVEGAS) →
-- защита дыхания, кожи, глаз 0..1; противогаз и костюм хим. защиты дают её через систему брони).
AetherGas.RegisterMaskProvider("jmod", function(ply)
    if not (JMod and JMod.GetArmorBiologicalResistance) then return 0 end
    local inhale = JMod.GetArmorBiologicalResistance(ply, DMG_NERVEGAS)
    return tonumber(inhale) or 0
end)

-- Z-City (режим; сверено: homigrad/organism/tier_1/sv_input.lua — урон DMG_NERVEGAS обнуляется, если на лице
-- противогаз ply.armors.face == "mask2" или игрок — Combine). Остальной урон газов Z-City берёт своим
-- «организмом» (hg.organism.GasDamage) — Aether наносит его штатным DMG_*.
AetherGas.RegisterMaskProvider("zcity", function(ply)
    local a = ply.armors
    if istable(a) and a.face == "mask2" then return 1 end
    if ply.PlayerClassName == "Combine" then return 1 end
    return 0
end)

-- GChem — Chemical Warfare (сверено: gc_functions.lua — ply.GChem.IsMasked / IsSuited)
AetherGas.RegisterMaskProvider("gchem", function(ply)
    local g = ply.GChem
    return (istable(g) and (g.IsMasked or g.IsSuited)) and 1 or 0
end)

AetherGas.RegisterMaskProvider("hook", function(ply)
    local r = hook.Run("AetherGas.HasGasMask", ply)
    if r == true then return 1 end
    return tonumber(r) or 0
end)

--- Защита дыхания от противогазов других модов: доля 0..1, имя лучшего поставщика и его opts.
-- def — описание газа (может быть nil: «есть ли вообще чужая маска»).
function AetherGas.ExternalMask(ply, def)
    local best, bestName, bestOpts = 0, nil, nil
    for i = 1, #Providers do
        local p = Providers[i]
        local ok, res = pcall(p.fn, ply, def)   -- чужой код: ошибка поставщика не должна ломать урон
        if ok then
            local v = res == true and 1 or tonumber(res) or 0
            if v > best then best, bestName, bestOpts = math.min(1, v), p.name, p.opts end
        end
    end
    return best, bestName, bestOpts
end

--- Костюм химзащиты (кожа закрыта): снимает и кожное действие зарина/иприта.
-- GBombs hazmat suit (ply.hazsuited); JMod — вторая величина GetArmorBiologicalResistance (защита кожи,
-- сверено: sv_init.lua «VictimFaceProtection, VictimSkinProtection = …») ≥ 90 %;
-- сторонние аддоны — хук AetherGas.HasGasSuit(ply) → true.
function AetherGas.HasGasSuit(ply)
    if ply:GetNW2Bool("AetherSuit", false) or ply.hazsuited == true then return true end
    if istable(ply.GChem) and ply.GChem.IsSuited then return true end
    if JMod and JMod.GetArmorBiologicalResistance then
        local ok, _, skin = pcall(JMod.GetArmorBiologicalResistance, ply, DMG_NERVEGAS)
        if ok and (tonumber(skin) or 0) >= 0.9 then return true end
    end
    return hook.Run("AetherGas.HasGasSuit", ply) == true
end

-- Связь с GBombs в обратную сторону: пока надета маска Aether, газы GBombs тоже считают игрока защищённым,
-- а его собственную маску поверх нашей надеть нельзя (gas_mask.lua проверяет gasmasked).
timer.Create("AetherGas.Compat.GBombsSync", 0.5, 0, function()
    for _, ply in ipairs(player.GetAll()) do
        -- Чужую маску надели поверх нашей → нашу снимаем в карман (двух масок одновременно не бывает).
        if AetherGas.HasMask(ply) and AetherGas.ExternalMask(ply) >= 0.5 then
            ply:SetNW2Bool("AetherMask", false)
            AetherGas.Notify(ply, 0, "hint.mask_to_pocket")
        end
    end
    if not scripted_ents.Get("gas_mask") then return end
    for _, ply in ipairs(player.GetAll()) do
        local ours = AetherGas.HasMask(ply)
        if ours and ply.gasmasked ~= true then
            ply.gasmasked, ply.AetherSetGBMask = true, true
        elseif not ours and ply.AetherSetGBMask then
            ply.gasmasked, ply.AetherSetGBMask = false, nil
        end
    end
end)

---------------------------------------------------------------------------------------------------
-- Вертолёты: поток от винта
---------------------------------------------------------------------------------------------------
local Helis = AetherGas.CompatHelis or {}
AetherGas.CompatHelis = Helis
local HELI_BASES = { "wac_hc_base", "lvs_base_helicopter" }

local function IsHeli(ent)
    local cls = ent:GetClass()
    for i = 1, #HELI_BASES do
        if cls == HELI_BASES[i] or scripted_ents.IsBasedOn(cls, HELI_BASES[i]) then return true end
    end
    return false
end

local function RotorSpinning(ent)
    if ent.GetEngineActive then return ent:GetEngineActive() end          -- LVS
    if ent.active ~= nil then return ent.active == true end              -- WAC
    local rpm = ent.rotorRpm or ent.engineRpm
    return rpm ~= nil and rpm > 0.1
end

hook.Add("OnEntityCreated", "AetherGas.Compat.Helis", function(ent)
    timer.Simple(0, function()
        if IsValid(ent) and IsHeli(ent) then Helis[ent] = true end
    end)
end)
hook.Add("EntityRemoved", "AetherGas.Compat.Helis", function(ent) Helis[ent] = nil end)

local ROTOR_UP, WASH_RADIUS, WASH_FORCE = 120, 520, 650
timer.Create("AetherGas.Compat.RotorWash", 0.25, 0, function()
    if Spatial.Pool.used == 0 or next(Helis) == nil then return end
    for ent in pairs(Helis) do
        if IsValid(ent) and RotorSpinning(ent) then
            -- Центр импульса над вертолётом: толчок идёт вниз и в стороны, как от реального винта
            Solver.BlastAt(ent:GetPos() + ent:GetUp() * ROTOR_UP, WASH_RADIUS, WASH_FORCE, true)
        end
    end
end)

---------------------------------------------------------------------------------------------------
-- Огнетушитель: струя толкает и разбавляет газ
---------------------------------------------------------------------------------------------------
timer.Create("AetherGas.Compat.Extinguisher", 0.1, 0, function()
    if Spatial.Pool.used == 0 then return end
    for _, ply in ipairs(player.GetAll()) do
        local w = ply:GetActiveWeapon()
        if IsValid(w) and string.StartWith(w:GetClass(), "weapon_extinguisher") and ply:KeyDown(IN_ATTACK)
            and (w.IsInfinite or w:Ammo1() > 0) then
            local a = ply:GetShootPos()
            Solver.PushRayAt(a, a + ply:GetAimVector() * 320, 70, 420, 0.06)
        end
    end
end)

---------------------------------------------------------------------------------------------------
-- Отчёт
---------------------------------------------------------------------------------------------------
concommand.Add("aether_compat_report", function(ply)
    if IsValid(ply) and not (ply:IsSuperAdmin() or game.SinglePlayer()) then return end
    local function out(s)
        if IsValid(ply) then ply:PrintMessage(HUD_PRINTCONSOLE, s .. "\n") else print(s) end
    end
    local function yes(b) return b and "yes" or "no" end
    out("[Aether] compatibility:")
    out("  StormFox 2 (wind):           " .. yes(StormFox2 ~= nil))
    out("  vFire (fire):                " .. yes(scripted_ents.Get("vfire") ~= nil))
    out("  JMod (EZ mask):              " .. yes(JMod ~= nil))
    out("  Rebirth gas mask:            " .. yes(weapons.GetStored("weapon_bo1_gasmask") ~= nil))
    out("  GChem (mask/suit):           " .. yes(scripted_ents.GetStored("ent_gchem_mask_chemical") ~= nil))
    out("  Z-City (gamemode):           " .. yes(engine.ActiveGamemode() == "zcity"))
    out("  GSmoke (exhaled smoke):      " .. yes(GNarcotics ~= nil))
    out("  Wiremod (device I/O):        " .. yes(WireLib ~= nil))
    out("  GMod Bombs 5 (mask/suit):    " .. yes(scripted_ents.Get("gas_mask") ~= nil or scripted_ents.Get("hazmat_suit") ~= nil))
    out("  VJ Base (NPC blinding):      " .. yes(VJBASE_VERSION ~= nil or VJ ~= nil))
    out("  DrGBase (NextBot blinding):  " .. yes(DrGBase ~= nil))
    out("  WAC helicopters:             " .. yes(scripted_ents.Get("wac_hc_base") ~= nil))
    out("  LVS helicopters:             " .. yes(scripted_ents.Get("lvs_base_helicopter") ~= nil))
    out("  Fire extinguisher:           " .. yes(weapons.Get("weapon_extinguisher") ~= nil))
    out("  Procedural Wall Destruction: " .. yes(scripted_ents.Get("proceduralwall") ~= nil))
    local names = {}
    for i = 1, #Providers do names[i] = Providers[i].name end
    out("  mask providers: " .. table.concat(names, ", "))
    for _, p in ipairs(player.GetAll()) do
        local prot, who = AetherGas.ExternalMask(p)
        out(string.format("  %s: Aether mask %s, other mod protection %d%% (%s)", p:Nick(), yes(AetherGas.HasMask(p)), prot * 100, who or "no"))
    end
end, nil, "Aether: detected mods and which mask each player wears")

---------------------------------------------------------------------------------------------------
-- GSmoke (сверено: sv_gnarcotics_core.lua — GNarcotics.BroadcastSmokePuff(ply, density, skipFirstPerson)
-- рассылает частицы выдоха; оружие weapon_gnarc_* с NetworkVar IsLit). Выдох сигареты/вейпа добавляет
-- в сетку облачко «tobacco_smoke» — дым из вентилятора уносит, в комнате он копится. Тлеющая сигарета,
-- сигара, косяк или трубка (не вейп) — открытый огонь: поджигает горючий газ у лица.
---------------------------------------------------------------------------------------------------
local function HookGSmoke()
    local G = GNarcotics
    if not (G and G.BroadcastSmokePuff) or G.AetherWrapped then return end
    local original = G.BroadcastSmokePuff
    G.AetherWrapped = true
    G.BroadcastSmokePuff = function(ply, density, skipFirstPerson)
        original(ply, density, skipFirstPerson)
        if not IsValid(ply) or not AetherGas.CVar.Enabled:GetBool() then return end
        local aim = ply:GetAimVector()
        local amount = math.Clamp((tonumber(density) or 1) * 0.6, 0.1, 2)
        AetherGas.Solver.PuffAt("tobacco_smoke", ply:EyePos() + aim * 12 - Vector(0, 0, 3), amount, nil, aim * 70, 0)
    end
end
hook.Add("InitPostEntity", "AetherGas.Compat.GSmoke", HookGSmoke)
HookGSmoke()   -- lua refresh

local FLAME_WEAPONS = { weapon_gnarc_cigarette = true, weapon_gnarc_cigar = true, weapon_gnarc_joint = true,
    weapon_gnarc_pipe = true, weapon_gnarc_cigarette_nohud = true, weapon_gnarc_cigar_nohud = true,
    weapon_gnarc_joint_nohud = true, weapon_gnarc_pipe_nohud = true }
timer.Create("AetherGas.Compat.GSmokeFlame", 0.5, 0, function()
    if not GNarcotics or Spatial.Pool.used == 0 then return end
    if CurTime() - (Solver.FlammableSeen or -100) > 2 then return end
    for _, ply in ipairs(player.GetAll()) do
        local w = ply:GetActiveWeapon()
        if IsValid(w) and FLAME_WEAPONS[w:GetClass()] and w.GetIsLit and w:GetIsLit() then
            local e = ply:EyePos()
            local key = Solver.FlammableAt(e.x, e.y, e.z)
            if key then Solver.BroadcastIgnite(key) end
        end
    end
end)
