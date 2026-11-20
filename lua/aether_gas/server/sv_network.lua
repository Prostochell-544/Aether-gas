-- lua/aether_gas/server/sv_network.lua
--[[
    Серверная игровая логика и синхронизация.

    Воздействие (каждые 0.25 с, игроки + отслеживаемые NPC/NextBot):
      • проба газа у глаз (Solver.Sample) → урон damage·c·dt·aether_damage_scale выше порога,
        тип урона из реестра; дробный урон копится, чтобы не терять 0.3 HP за тик;
      • противогаз (maskProtects) гасит урон и тратит фильтр пропорционально концентрации;
        пустой фильтр не защищает;
      • кашель (screen.cough) — звук и толчок камеры, слышат все;
      • замедление slowdown·c → NW2-float, применяется в общем SetupMove (sh_solver).

    Слепота: если оптическая толщина дыма между глазами NPC и его врагом ≥ BLIND_DEPTH, NPC теряет
    врага (ClearEnemyMemory + SetEnemy(NULL)); у NextBot вызывается SetEnemy(nil), если он есть.
    Хук AetherGas.ShouldBlind(npc, enemy) → false отменяет. Публичный AetherGas.IsLineObscured(a, b).

    Синхронизация: клиент считает облака сам, но time-slicing и задержки событий дают расхождение.
    Раз в aether_sync_interval сервер шлёт всем сжатый снимок следующего активного чанка (по кругу);
    новому игроку — все активные чанки сразу. Снимок ≈ 100–500 байт, сеть почти не нагружается.
]]

local AetherGas = AetherGas
local Solver    = AetherGas.Solver
local Spatial   = AetherGas.Spatial
local C         = AetherGas.Const
local CV        = AetherGas.CVar
local P         = AetherGas.GasParams

local IsValid, pairs, floor, random = IsValid, pairs, math.floor, math.random

local PERIOD       = 0.25
local BLIND_DEPTH  = 1.2     -- ≈ два-три вокселя плотного дыма между глазами и целью
local SNAP_MAX_BYTES = 48000 -- одно net-сообщение снимков (лимит 64 КБ)

local Tracked = AetherGas.TrackedNPCs or {}   -- [ent] = true: NPC и NextBot
AetherGas.TrackedNPCs = Tracked
local DamageAcc = setmetatable({}, { __mode = "k" })

---------------------------------------------------------------------------------------------------
-- Противогаз
---------------------------------------------------------------------------------------------------
-- Маска — предмет у игрока (AetherMaskOwned) и отдельно «надета» (AetherMask). Фильтр тратится только надетой.
-- Надеть/снять: E+R, «!mask» в чат, aether_mask_toggle. Выбросить: aether_mask_drop. Смерть — маска выпадает.
function AetherGas.HasMask(ply)            -- надета
    return ply:GetNW2Bool("AetherMask", false)
end

function AetherGas.OwnsMask(ply)
    return ply:GetNW2Bool("AetherMaskOwned", false)
end

-- Понятное имя чужой маски для сообщений игроку
local MASK_NAMES = { gbombs5 = "GMod Bombs", jmod = "JMod", rebirth = "Rebirth", zcity = "Z-City", gchem = "GChem",
    hook = "@hint.another_mod" }
local function ExternalName(ply)
    if not AetherGas.ExternalMask then return nil end
    local v, name = AetherGas.ExternalMask(ply)
    if v < 0.5 then return nil end
    return MASK_NAMES[name] or name or "@hint.another_mod"
end

--- Подсказка (всплывающая + строка в чат) на языке игрока: key — ключ sh_lang.lua.
local function Hint(ply, key, ...) AetherGas.Notify(ply, 1, key, ...) end

function AetherGas.GiveMask(ply, filter)
    if not IsValid(ply) or not ply:IsPlayer() or AetherGas.OwnsMask(ply) then return false end
    local external = ExternalName(ply)
    ply:SetNW2Bool("AetherMaskOwned", true)
    ply:SetNW2Bool("AetherMask", external == nil)   -- поверх чужой маски не надевается — кладётся в карман
    if external then
        Hint(ply, "hint.mask_pocket", external)
    elseif not ply.AetherMaskHinted then
        ply.AetherMaskHinted = true
        Hint(ply, "hint.mask_on")
    end
    ply:SetNW2Float("AetherFilter", filter or CV.MaskFilter:GetFloat())
    ply:EmitSound("items/ammopickup.wav", 60)
    return true
end

function AetherGas.ToggleMask(ply)
    if not IsValid(ply) or not ply:Alive() or not AetherGas.OwnsMask(ply) then return end
    if (ply.AetherMaskNext or 0) > CurTime() then return end
    ply.AetherMaskNext = CurTime() + 0.8
    local wear = not AetherGas.HasMask(ply)
    if wear then
        local external = ExternalName(ply)
        if external then
            Hint(ply, "hint.mask_already", external)
            return
        end
    end
    ply:SetNW2Bool("AetherMask", wear)
    ply:EmitSound(wear and "items/ammopickup.wav" or "physics/cardboard/cardboard_box_impact_soft2.wav", 60)
end

function AetherGas.RemoveMask(ply, drop)
    if not IsValid(ply) or not AetherGas.OwnsMask(ply) then return end
    local filter = ply:GetNW2Float("AetherFilter", 0)
    ply:SetNW2Bool("AetherMaskOwned", false)
    ply:SetNW2Bool("AetherMask", false)
    ply:SetNW2Float("AetherFilter", 0)
    if drop then
        local e = ents.Create("aether_gasmask")
        if IsValid(e) then
            local pos = ply:Alive() and (ply:EyePos() + ply:GetAimVector() * 24) or ply:WorldSpaceCenter()
            e:SetPos(pos)
            e:SetFilter(filter)
            e:Spawn()
        end
    end
end

-- Запасные фильтры (NW2Int AetherSpareFilters): сущность aether_filter. Почти пустой фильтр меняется сразу,
-- иначе коробка идёт в запас и вкручивается автоматически, когда фильтр в маске кончится.
AetherGas.MAX_SPARE_FILTERS = 3

function AetherGas.AddFilter(ply)
    if not AetherGas.OwnsMask(ply) then
        AetherGas.Notify(ply, 0, "hint.need_mask")
        return false
    end
    local max = CV.MaskFilter:GetFloat()
    if ply:GetNW2Float("AetherFilter", 0) < max * 0.5 then
        ply:SetNW2Float("AetherFilter", max)
        ply:EmitSound("items/ammopickup.wav", 60, 90)
        return true
    end
    local spare = ply:GetNW2Int("AetherSpareFilters", 0)
    if spare >= AetherGas.MAX_SPARE_FILTERS then
        AetherGas.Notify(ply, 0, "hint.filters_full")
        return false
    end
    ply:SetNW2Int("AetherSpareFilters", spare + 1)
    ply:EmitSound("items/ammopickup.wav", 60, 110)
    return true
end

--- Фильтр кончился: вкрутить запасной, если есть. true — заменён.
local function SwapSpareFilter(ply)
    local spare = ply:GetNW2Int("AetherSpareFilters", 0)
    if spare <= 0 then return false end
    ply:SetNW2Int("AetherSpareFilters", spare - 1)
    ply:SetNW2Float("AetherFilter", CV.MaskFilter:GetFloat())
    ply:EmitSound("weapons/smg1/switch_burst.wav", 60, 80)
    return true
end

-- 0 — надеть/снять, 1 — выбросить
net.Receive(C.NET_MASK, function(_, ply)
    if not IsValid(ply) or not ply:Alive() then return end
    if net.ReadUInt(2) == 1 then AetherGas.RemoveMask(ply, true) else AetherGas.ToggleMask(ply) end
end)

hook.Add("KeyPress", "AetherGas.Network.MaskKeys", function(ply, key)
    if key == IN_RELOAD and ply:KeyDown(IN_USE) then AetherGas.ToggleMask(ply) end
    -- E + Alt (шаг): снять костюм химзащиты (выпадает под ноги, его можно снова надеть через E)
    if key == IN_WALK and ply:KeyDown(IN_USE) and AetherGas.HasSuit and AetherGas.HasSuit(ply) then
        if (ply.AetherSuitNext or 0) > CurTime() then return end
        ply.AetherSuitNext = CurTime() + 1
        AetherGas.RemoveSuit(ply, true)
        ply:EmitSound("npc/combine_soldier/gear" .. math.random(1, 6) .. ".wav", 70)
    end
end)

hook.Add("PlayerSay", "AetherGas.Network.MaskChat", function(ply, text)
    local t = string.lower(string.Trim(text))
    if t == "!mask" or t == "/mask" then
        AetherGas.ToggleMask(ply)
        return ""
    end
end)

---------------------------------------------------------------------------------------------------
-- Костюм химзащиты (aether_hazmat): NW2 «AetherSuit». Закрывает только кожу: кожное действие зарина/иприта,
-- новое заражение, пар вполовину. Дыхательного аппарата в нём нет — противогаз надевается отдельно.
---------------------------------------------------------------------------------------------------
function AetherGas.HasSuit(ply) return ply:GetNW2Bool("AetherSuit", false) end

function AetherGas.WearSuit(ply)
    if not IsValid(ply) or not ply:IsPlayer() or not ply:Alive() then return false end
    if AetherGas.HasSuit(ply) then
        AetherGas.Notify(ply, 0, "hint.suit_already")
        return false
    end
    ply:SetNW2Bool("AetherSuit", true)
    ply:EmitSound("npc/combine_soldier/gear" .. math.random(1, 6) .. ".wav", 70)
    Hint(ply, "hint.suit_on")
    return true
end

function AetherGas.RemoveSuit(ply, drop)
    if not IsValid(ply) or not AetherGas.HasSuit(ply) then return end
    ply:SetNW2Bool("AetherSuit", false)
    if drop then
        local e = ents.Create("aether_hazmat")
        if IsValid(e) then
            e:SetPos(ply:Alive() and (ply:GetPos() + ply:GetForward() * 30 + Vector(0, 0, 10)) or ply:WorldSpaceCenter())
            e:Spawn()
        end
    end
end

concommand.Add("aether_suit_drop", function(ply) if IsValid(ply) then AetherGas.RemoveSuit(ply, true) end end,
    nil, "Aether: take off the hazmat suit (it drops on the ground)")

hook.Add("PlayerSay", "AetherGas.Network.SuitChat", function(ply, text)
    local t = string.lower(string.Trim(text))
    if t == "!suit" or t == "/suit" then
        AetherGas.RemoveSuit(ply, true)
        return ""
    end
end)

hook.Add("PlayerDeath", "AetherGas.Network.Mask", function(ply)
    AetherGas.RemoveSuit(ply, true)
    AetherGas.RemoveMask(ply, true)
    -- запасные фильтры выпадают рядом с телом
    for i = 1, ply:GetNW2Int("AetherSpareFilters", 0) do
        local e = ents.Create("aether_filter")
        if IsValid(e) then
            e:SetPos(ply:WorldSpaceCenter() + VectorRand() * 8 + Vector(0, 0, 8 * i))
            e:Spawn()
        end
    end
    ply:SetNW2Int("AetherSpareFilters", 0)
end)
hook.Add("PlayerSpawn", "AetherGas.Network.Reset", function(ply)
    ply:SetNW2Float("AetherSlow", 0)
    DamageAcc[ply] = nil
    if AetherGas.ResetBody then AetherGas.ResetBody(ply) end
    ply:SetNW2Float("AetherDose", 0)
    ply:SetNW2Int("AetherDoseGas", 0)
    ply:SetNW2Float("AetherContam", 0)
    ply:SetNW2Int("AetherContamGas", 0)
end)

---------------------------------------------------------------------------------------------------
-- Отслеживание NPC/NextBot (без опроса всех сущностей каждый тик)
---------------------------------------------------------------------------------------------------
local function Track(ent)
    if IsValid(ent) and (ent:IsNPC() or ent:IsNextBot()) then Tracked[ent] = true end
end
hook.Add("OnEntityCreated", "AetherGas.Network.Track", function(ent)
    timer.Simple(0, function() Track(ent) end)   -- класс/флаги NPC доступны после Spawn
end)
hook.Add("EntityRemoved", "AetherGas.Network.Track", function(ent) Tracked[ent] = nil end)
for _, e in ipairs(ents.GetAll()) do Track(e) end

---------------------------------------------------------------------------------------------------
-- Воздействие газа
---------------------------------------------------------------------------------------------------
--- Невидимая точечная сущность «aether_gas» — атакующий/инфлектор урона газом: лента убийств
-- показывает свою иконку и имя «Toxic Gas» вместо worldspawn.
function AetherGas.GasInflictor()
    local e = AetherGas.GasEnt
    if not IsValid(e) then
        e = ents.Create("aether_gas")
        if IsValid(e) then e:Spawn() else e = game.GetWorld() end
        AetherGas.GasEnt = e
    end
    return e
end

local COUGH_SOUNDS ={ "ambient/voices/cough1.wav", "ambient/voices/cough2.wav", "ambient/voices/cough3.wav", "ambient/voices/cough4.wav" }

-- Замер по телу: глаза (дыхание целиком), пояс и ноги. Облако рисуется крупнее своих ячеек, и стоящий
-- «по грудь» в хлоре видит газ на экране — значит, дышит им: пояс даёт 70 % вдоха, ноги 30 %.
-- Замедление — по самому плотному из трёх замеров (идти по газу вброд тяжело на любой высоте).
local BODY_INHALE = 0.7
local FEET_INHALE = 0.3

local function SampleBody(ent)
    local eye = ent:EyePos()
    local ge, ce = Solver.Sample(eye.x, eye.y, eye.z)
    local mid = ent:WorldSpaceCenter()
    local gm, cm = Solver.Sample(mid.x, mid.y, mid.z)
    local feet = ent:GetPos()
    local gf, cf = Solver.Sample(feet.x, feet.y, feet.z + 10)
    local g, c = ge, ce
    if gm ~= 0 and cm * BODY_INHALE > c then g, c = gm, cm * BODY_INHALE end
    if gf ~= 0 and cf * FEET_INHALE > c then g, c = gf, cf * FEET_INHALE end
    local slowG, slowC = ge, ce
    if cm > slowC then slowG, slowC = gm, cm end
    if cf > slowC then slowG, slowC = gf, cf end
    return g, c, eye, slowG, slowC
end
AetherGas.SampleBody = SampleBody

---------------------------------------------------------------------------------------------------
-- Доза и заражение.
--   Доза газа g: D += c·утечка·dt в облаке; выведение D *= exp(−dt / clearance). Эквивалент концентрации
--   в организме L = D / clearance. Доля linger урона и эффектов идёт от L — зарин и иприт продолжают
--   действовать после выхода из облака, CS «держит» слёзы, CO — потемнение. NW2 «AetherDose» = L самого
--   сильного газа, «AetherDoseGas» — его id (клиентские эффекты, cl_effects).
--   Заражение кожи/одежды: стойкий агент (deposit > 0) без костюма оседает на игроке (NW2 «AetherContam»,
--   «AetherContamGas»): ожог кожи и след газа вокруг, пока агент сам не испарится. Костюм, надетый
--   после заражения, уже не помогает — агент под ним.
---------------------------------------------------------------------------------------------------
local Body = setmetatable({}, { __mode = "k" })   -- [ent] = { dose = { [gasId] = D }, contam, contamGas, treat }
local CONTAM_RATE  = 0.6     -- доля дозы осаждения, попадающая на кожу без костюма
local CONTAM_DECAY = 0.004   -- 1/с: само по себе заражение сходит медленно
local CONTAM_EMIT  = 0.06    -- доля заражения в секунду, испаряющаяся вокруг игрока

local function BodyState(ent)
    local b = Body[ent]
    if not b then
        b = { dose = {}, contam = 0, contamGas = 0, treat = {} }
        Body[ent] = b
    end
    return b
end

function AetherGas.ResetBody(ent) Body[ent] = nil end

function AetherGas.GetDose(ent, gas)
    local b = Body[ent]
    if not b then return 0 end
    local id = isnumber(gas) and gas or AetherGas.GetGasId(gas)
    return (b.dose[id] or 0) / P.Clearance[id]
end

function AetherGas.Decontaminate(ent)
    local b = Body[ent]
    if b then b.contam, b.contamGas = 0, 0 end
    if ent:IsPlayer() then
        ent:SetNW2Float("AetherContam", 0)
        ent:SetNW2Int("AetherContamGas", 0)
    end
end

---------------------------------------------------------------------------------------------------
-- Антидоты. AetherGas.Antidotes[вид] = {
--   gases     — имена газов, на которые действует;
--   remove    — доля накопленной дозы, снимаемая сразу (0..1);
--   clearance — во сколько раз быстрее выводится доза, пока действует;
--   harm      — множитель вреда от газа (немедленного и отложенного) и судорог, пока действует;
--   duration  — сколько секунд действует (атропин заранее — профилактика);
--   decon     — снять заражение кожи и одежды;
--   prophylaxis — можно применить без отравления (иначе — «нечего лечить», предмет не тратится) }.
-- Лечение на сущности: Body.treat[gasId] = { t = до какого времени, clr, harm }.
-- Сторонние моды: AetherGas.RegisterAntidote(вид, описание); хук AetherGas.Antidote(ent, вид) → false — отменить.
---------------------------------------------------------------------------------------------------
AetherGas.Antidotes = AetherGas.Antidotes or {}

function AetherGas.RegisterAntidote(kind, def)
    def.gases = def.gases or {}
    def.remove, def.clearance, def.harm = def.remove or 0, def.clearance or 1, def.harm or 1
    def.duration = def.duration or 0
    AetherGas.Antidotes[kind] = def
end

-- атропин (автошприц, как АИ-2): нервно-паралитические — зарин
AetherGas.RegisterAntidote("atropine", { gases = { "sarin" }, remove = 0.5, clearance = 4, harm = 0.35,
    duration = 180, prophylaxis = true, sound = "items/medshot4.wav" })
-- ИПП (индивидуальный противохимический пакет): снимает заражение кожи, иприт и зарин с кожи
AetherGas.RegisterAntidote("decon", { gases = {}, decon = true, sound = "ambient/water/water_spray1.wav" })
-- промывка глаз: слезоточивый газ, аммиак
AetherGas.RegisterAntidote("eyewash", { gases = { "tear_gas", "ammonia" }, remove = 0.8, clearance = 6, harm = 0.3,
    duration = 30, sound = "ambient/water/water_spray1.wav" })
-- кислород: угарный газ, углекислота, азот (удушье — гипоксия)
AetherGas.RegisterAntidote("oxygen", { gases = { "co_smoke", "co2", "nitrogen" }, remove = 0.7, clearance = 5,
    harm = 0.2, duration = 60, sound = "ambient/gas/steam2.wav" })

--- Применить антидот вида kind к сущности. Возвращает true, если подействовал (предмет тратится).
function AetherGas.ApplyAntidote(ent, kind)
    local def = AetherGas.Antidotes[kind]
    if not def or not IsValid(ent) then return false end
    if hook.Run("AetherGas.Antidote", ent, kind) == false then return false end
    local b = BodyState(ent)
    b.treat = b.treat or {}
    local helped = false
    local now = CurTime()
    for _, name in ipairs(def.gases) do
        local id = AetherGas.GetGasId(name)
        if id then
            local d = b.dose[id]
            if d and d > 0.002 then
                b.dose[id] = d * (1 - def.remove)
                helped = true
            end
            if def.duration > 0 and (helped or def.prophylaxis) then
                b.treat[id] = { t = now + def.duration, clr = def.clearance, harm = def.harm }
            end
        end
    end
    if def.decon and b.contam > 0.01 then
        AetherGas.Decontaminate(ent)
        helped = true
    end
    if not helped and not def.prophylaxis then return false end
    if def.sound then
        -- Часть звуков HL2 зациклена (steam2, water_spray1): EmitSound играл бы их бесконечно.
        -- CreateSound + затухание через soundTime (по умолчанию 1.2 с) — конечный звук для любого файла.
        local snd = CreateSound(ent, def.sound)
        snd:SetSoundLevel(60)
        snd:Play()
        timer.Simple(def.soundTime or 1.2, function() if snd then snd:FadeOut(0.4) end end)
    end
    return true
end

--- Действующее лечение газа g: (множитель выведения, множитель вреда) — 1, 1 без лечения.
local function Treatment(b, g)
    local tr = b.treat and b.treat[g]
    if not tr then return 1, 1 end
    if CurTime() > tr.t then
        b.treat[g] = nil
        return 1, 1
    end
    return tr.clr, tr.harm
end

local function Hurt(ent, amount, dmgType, pos)
    local acc = (DamageAcc[ent] or 0) + amount
    if acc >= 1 then
        local whole = floor(acc)
        acc = acc - whole
        local info = DamageInfo()
        info:SetDamage(whole)
        info:SetDamageType(dmgType)
        local gasEnt = AetherGas.GasInflictor()
        info:SetAttacker(gasEnt)
        info:SetInflictor(gasEnt)
        info:SetDamagePosition(pos)
        ent:TakeDamageInfo(info)
    end
    DamageAcc[ent] = acc
end

--- Выведение дозы, отложенный урон и эффекты, заражение — каждый тик, в облаке и вне его.
local function ApplyBody(ent, isPlayer, scale)
    local b = Body[ent]
    if not b then return end
    local bestL, bestG = 0, 0
    for g, d in pairs(b.dose) do
        local clr, harm = Treatment(b, g)
        d = d * math.exp(-PERIOD * clr / P.Clearance[g])
        if d < 0.002 then
            b.dose[g] = nil
        else
            b.dose[g] = d
            local L = d / P.Clearance[g]
            local linger = P.Linger[g]
            if linger > 0 then
                local dmg = P.Damage[g] * L * linger * PERIOD * scale * harm
                if dmg > 0 then Hurt(ent, dmg, AetherGas.GasById[g].damageType, ent:EyePos()) end
            end
            if L * linger > bestL then bestL, bestG = L * linger, g end
        end
    end
    -- заражение кожи и одежды
    if b.contam > 0 then
        local g = b.contamGas
        local def = AetherGas.GasById[g]
        if def then
            Hurt(ent, P.Damage[g] * def.skinDamage * b.contam * PERIOD * scale, def.damageType, ent:WorldSpaceCenter())
            local emit = b.contam * CONTAM_EMIT * PERIOD
            if emit > 0.002 then Solver.PuffAt(def.name, ent:WorldSpaceCenter(), emit * 4, nil, nil, 0) end
        end
        b.contam = b.contam * (1 - CONTAM_DECAY * PERIOD) - b.contam * CONTAM_EMIT * PERIOD
        if b.contam < 0.01 then b.contam, b.contamGas = 0, 0 end
        if isPlayer then
            if math.abs(ent:GetNW2Float("AetherContam", 0) - b.contam) > 0.02 then ent:SetNW2Float("AetherContam", b.contam) end
            if ent:GetNW2Int("AetherContamGas", 0) ~= b.contamGas then ent:SetNW2Int("AetherContamGas", b.contamGas) end
        end
    end
    if isPlayer then
        if math.abs(ent:GetNW2Float("AetherDose", 0) - bestL) > 0.01 then ent:SetNW2Float("AetherDose", bestL) end
        if ent:GetNW2Int("AetherDoseGas", 0) ~= bestG then ent:SetNW2Int("AetherDoseGas", bestG) end
        -- кашель после выхода из облака, пока доза не выведена
        local def = AetherGas.GasById[bestG]
        local cough = def and def.screen and def.screen.cough or 0
        if cough > 0 and random() < cough * bestL * 0.25 then
            ent:EmitSound(COUGH_SOUNDS[random(1, #COUGH_SOUNDS)], 70, random(92, 108))
            ent:ViewPunch(Angle(random(2, 5), random(-2, 2), 0))
        end
    end
end

local function ApplyExposure(ent, isPlayer, scale)
    local g, c, eye, slowG, slowC = SampleBody(ent)

    if isPlayer then
        local slow = slowG ~= 0 and P.Slowdown[slowG] * slowC or 0
        if math.abs(slow - ent:GetNW2Float("AetherSlow", 0)) > 0.02 then ent:SetNW2Float("AetherSlow", slow) end
    end
    if g == 0 or c < P.DamageThreshold[g] then return end

    local def = AetherGas.GasById[g]
    -- Хук для других модов: false — пропустить воздействие (свой иммунитет, режим, класс игрока…)
    local delta = c * PERIOD
    if hook.Run("AetherGas.PreExposure", ent, def.name, c, delta) == false then return end
    if hook.Run("Aether_PreGasExposure", ent, def.name, c, delta) == false then return end
    -- Костюм химзащиты Aether закрывает кожу, но не дыхание: пар обжигает вполовину
    if isPlayer and def.damageType == DMG_BURN and ent:GetNW2Bool("AetherSuit", false) then scale = scale * 0.5 end
    -- Защита дыхания 0..1: своя маска (тратит фильтр) или маска другого мода (sv_compat.lua).
    -- Утечка = вдох·(1 − защита дыхания) + кожа·(1 − костюм), skinDamage — доля кожного действия
    -- (зарин, иприт). Полная защита от них — противогаз И костюм.
    local prot, masked = 0, false
    if isPlayer and def.maskProtects and AetherGas.HasMask(ent) then
        local filter = ent:GetNW2Float("AetherFilter", 0)
        if filter > 0 then
            masked, prot = true, 1
            filter = math.max(0, filter - PERIOD * (0.5 + c))
            ent:SetNW2Float("AetherFilter", filter)
            if filter == 0 and not SwapSpareFilter(ent) then ent:EmitSound("buttons/button10.wav", 60) end
        end
    end
    local ext, extOpts = 0, nil
    if isPlayer and def.maskProtects and not masked and AetherGas.ExternalMask then
        local _
        ext, _, extOpts = AetherGas.ExternalMask(ent, def)
    end
    -- Маска мода, которая сама поглощает урон своего типа и тратит фильтр (Rebirth): урон наносим целиком,
    -- её хук EntityTakeDamage его заблокирует; эффекты и кашель Aether всё равно гасятся по ext.
    local passDamage = extOpts and extOpts.passDamage and ext > 0
    if isPlayer and math.abs(ent:GetNW2Float("AetherExtMask", 0) - ext) > 0.01 then
        ent:SetNW2Float("AetherExtMask", ext)   -- клиенту: приглушить эффекты
    end
    if ext > prot then prot = ext end
    local suit = isPlayer and AetherGas.HasGasSuit and AetherGas.HasGasSuit(ent)
    local skin = def.maskProtects and def.skinDamage or 0
    local leak = (1 - skin) * (1 - prot) + (suit and 0 or skin)
    if leak <= 0.001 and not passDamage then return end
    local b = BodyState(ent)
    local _, harm = Treatment(b, g)   -- антидот снижает вред и судороги, но не вдыхание (доза копится)

    -- Судороги (зарин): толчки камеры, сильнее с концентрацией; противогаз их не снимает (кожа)
    local scr = def.screen
    if isPlayer and scr and scr.shake and random() < scr.shake * math.min(1, c * 6) * leak * harm then
        ent:ViewPunch(Angle(random(-6, 6), random(-6, 6), random(-4, 4)))
    end

    -- Немедленная часть урона; отложенная (linger) идёт от дозы в ApplyBody
    local dmg = P.Damage[g] * c * PERIOD * scale * harm * (passDamage and 1 or leak) * (passDamage and 1 or (1 - P.Linger[g]))
    if dmg > 0 then Hurt(ent, dmg, def.damageType, eye) end
    if not passDamage then b.dose[g] = (b.dose[g] or 0) + c * leak * PERIOD end
    -- стойкий агент оседает на коже и одежде (костюм не пускает новое заражение)
    if P.Deposit[g] > 0 and not suit then
        if b.contamGas ~= g and b.contam > 0.05 then
            -- уже заражён другим агентом: остаётся более опасный
            if P.Damage[g] > P.Damage[b.contamGas] then b.contamGas = g end
        else
            b.contamGas = g
        end
        b.contam = math.min(3, b.contam + c * P.Deposit[g] * CONTAM_RATE * 30 * PERIOD)
    end

    local cough = def.screen and def.screen.cough or 0
    if isPlayer and prot < 0.5 and cough > 0 and random() < cough * c * 0.35 then
        ent:EmitSound(COUGH_SOUNDS[random(1, #COUGH_SOUNDS)], 70, random(92, 108))
        ent:ViewPunch(Angle(random(3, 7), random(-2, 2), 0))
    end
end

---------------------------------------------------------------------------------------------------
-- Слепота в дыму
---------------------------------------------------------------------------------------------------
function AetherGas.IsLineObscured(a, b)
    return Solver.OpticalDepth(a.x, a.y, a.z, b.x, b.y, b.z, BLIND_DEPTH) >= BLIND_DEPTH
end

local function BlindCheck(ent)
    local enemy = ent.GetEnemy and ent:GetEnemy()
    if not IsValid(enemy) then return end
    if not AetherGas.IsLineObscured(ent:EyePos(), enemy.EyePos and enemy:EyePos() or enemy:WorldSpaceCenter()) then return end
    if hook.Run("AetherGas.ShouldBlind", ent, enemy) == false then return end
    if ent:IsNPC() then
        ent:ClearEnemyMemory(enemy)
        ent:SetEnemy(NULL)
    elseif ent.SetEnemy then
        ent:SetEnemy(nil)
    end
end

timer.Create("AetherGas.Network.Exposure", PERIOD, 0, function()
    if not CV.Enabled:GetBool() or Spatial.Pool.used == 0 then return end
    local scale = CV.DamageScale:GetFloat()
    local blind = CV.NPCBlind:GetBool()
    for _, ply in ipairs(player.GetAll()) do
        if ply:Alive() then
            ApplyExposure(ply, true, scale)
            ApplyBody(ply, true, scale)
        end
    end
    for ent in pairs(Tracked) do
        if IsValid(ent) then
            if ent:Health() > 0 then
                ApplyExposure(ent, false, scale)
                ApplyBody(ent, false, scale)
            end
            if blind then BlindCheck(ent) end
        else
            Tracked[ent] = nil
        end
    end
end)

-- Когда газа нет совсем, сбрасываем замедление тем, у кого оно осталось.
timer.Create("AetherGas.Network.SlowReset", 1, 0, function()
    if Spatial.Pool.used ~= 0 then return end
    for _, ply in ipairs(player.GetAll()) do
        if ply:GetNW2Float("AetherSlow", 0) > 0 then ply:SetNW2Float("AetherSlow", 0) end
    end
end)

---------------------------------------------------------------------------------------------------
-- Снимки чанков
---------------------------------------------------------------------------------------------------
local function SendSnapshots(slots, target)
    local i = 1
    while i <= #slots do
        local batch, bytes = {}, 0
        while i <= #slots and bytes < SNAP_MAX_BYTES and #batch < 255 do
            local slot = slots[i]
            local data = Solver.EncodeChunk(slot)
            batch[#batch + 1] = { Spatial.Pool.slotKey[slot], data }
            bytes = bytes + #data + 6
            i = i + 1
        end
        net.Start(C.NET_SNAPSHOT)
        net.WriteUInt(#batch, 8)
        for _, item in ipairs(batch) do
            net.WriteUInt(item[1], 21)
            net.WriteUInt(#item[2], 16)
            net.WriteData(item[2], #item[2])
        end
        if target then net.Send(target) else net.Broadcast() end
    end
end

local syncCursor, syncAcc = 0, 0
timer.Create("AetherGas.Network.Sync", 0.1, 0, function()
    local pool = Spatial.Pool
    if pool.used == 0 or player.GetCount() == 0 then return end
    syncAcc = syncAcc + 0.1
    if syncAcc < CV.SyncInterval:GetFloat() then return end
    syncAcc = 0
    for _ = 1, pool.highWater do
        syncCursor = syncCursor % pool.highWater + 1
        if pool.slotKey[syncCursor] ~= -1 and pool.slotCount[syncCursor] > 0 then
            SendSnapshots({ syncCursor })
            return
        end
    end
end)

hook.Add("AetherGas.ClientReady", "AetherGas.Network", function(ply)
    local pool, slots = Spatial.Pool, {}
    for slot = 1, pool.highWater do
        if pool.slotKey[slot] ~= -1 and pool.slotCount[slot] > 0 then slots[#slots + 1] = slot end
    end
    if #slots > 0 then SendSnapshots(slots, ply) end
end)

---------------------------------------------------------------------------------------------------
-- Меню Q: суперадмин меняет серверные ConVar'ы. Только белый список и только суперадмин.
---------------------------------------------------------------------------------------------------
local ADMIN_CVARS = {
    aether_enabled = true, aether_voxel_size = true, aether_max_chunks = true, aether_tick_budget = true,
    aether_probe_budget = true, aether_grates_block = true, aether_wind_speed = true, aether_wind_yaw = true,
    aether_wind_stormfox = true, aether_damage_scale = true, aether_npc_blind = true,
    aether_mask_filter = true, aether_sync_interval = true,
    aether_custom_gas_everyone = true, aether_gasgun_toxic_admin = true, aether_cylinder_style = true,
    aether_tunnel_strength = true, aether_fire_smoke = true, aether_fire_vfire = true, aether_vfire_wind = true,
}

net.Receive(C.NET_ADMIN_CVAR, function(_, ply)
    if not IsValid(ply) or not (ply:IsSuperAdmin() or game.SinglePlayer()) then return end
    local name, value = net.ReadString(), tonumber(net.ReadString())
    if not ADMIN_CVARS[name] or not value then return end
    RunConsoleCommand(name, tostring(value))
end)
