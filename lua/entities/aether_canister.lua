-- lua/entities/aether_canister.lua
-- Газовый баллон: «E» открывает/закрывает вентиль, запас конечен. Газ — keyvalue «gas» (в спавн-меню по баллону
-- на каждый газ), меню C → Gas type / Unmarked (old) look, тулган «Gas Duct / Hose» — шланг.
-- Keyvalue «plain» 1 — старый баллон без надписей (свой скин, газ внутри любой).
--
-- Повреждения (под давлением, вентиль не важен):
--   • пуля, дробь, арбалетный болт, удар ножом/ломом, сильный удар — пробоина: струя газа наружу по нормали,
--     реактивная тяга, до MAX_LEAKS дыр; запас уходит быстрее;
--   • горючий газ (водород, метан, сероводород…) взрывается от огня, взрыва, тока/энергии (AR2, гравипушка)
--     и крупного калибра (урон пули > BIG_CALIBER, кроме арбалета); 9 мм и дробь только пробивают —
--     а газ из пробоины уже может поджечь следующая искра;
--   • негорючий газ от взрыва разрывает баллон: весь остаток выходит залпом;
--   • баллон в огне: горючий через 2 с взрывается, негорючий травит через предохранительный клапан.
AddCSLuaFile()

ENT.Type      = "anim"
ENT.Base      = "base_anim"
ENT.PrintName = "Gas Cylinder"
ENT.Author    = "Aether"
ENT.Category  = "Aether Gas"
ENT.Spawnable = false   -- в спавн-меню — пресеты ниже (по одному на газ)

-- Пресеты спавн-меню: тот же класс, газ через KeyValues; иконка materials/entities/aether_cylinder_<газ>.png
for i = 1, #AetherGas.BaseGases do
    local name = AetherGas.BaseGases[i]
    local def = AetherGas.GetGas(name)
    if def then
        list.Set("SpawnableEntities", "aether_cylinder_" .. name, {
            PrintName = "Cylinder: " .. def.printName,
            ClassName = "aether_canister",
            Category  = "Aether Gas",
            KeyValues = { gas = name },
            DropToFloor = true,
            IconOverride = "entities/aether_cylinder_" .. name .. ".png",
        })
    end
end
list.Set("SpawnableEntities", "aether_cylinder_plain", {
    PrintName = "Cylinder: Unmarked (old)",
    ClassName = "aether_canister",
    Category  = "Aether Gas",
    KeyValues = { gas = "smoke", plain = "1" },
    DropToFloor = true,
    IconOverride = "entities/aether_cylinder_plain.png",
})

function ENT:KeyValue(key, value)
    key = string.lower(key)
    if key == "gas" and AetherGas.GetGas(value) then self.InitGas = value end
    if key == "plain" then self.InitPlain = tobool(value) end
end

local CAPACITY    = 120   -- единиц концентрации на весь баллон
local RATE        = 5     -- концентрация/с из вентиля
local LEAK_RATE   = 7     -- концентрация/с из одной пробоины (давление выше, чем через вентиль)
local MAX_LEAKS   = 3
local THRUST      = 700   -- реактивная тяга одной пробоины, юнит/с² на единицу массы
local BIG_CALIBER = 25    -- урон пули, выше которого горючий баллон взрывается (крупный калибр, винтовки)

function ENT:SetupDataTables()
    self:NetworkVar("String", 0, "GasName")
    self:NetworkVar("Bool", 0, "Open")
    self:NetworkVar("Float", 0, "Contents")
    self:NetworkVar("Bool", 1, "Plain")
    self:NetworkVar("Int", 0, "Leaks")
end

--- Скин: без надписей — отдельный, иначе по газу.
function ENT:UpdateSkin()
    self:SetSkin(self:GetPlain() and AetherGas.PLAIN_CYLINDER_SKIN or AetherGas.GasSkin(self:GetGasName()))
end

if CLIENT then
    function ENT:Draw()
        self:DrawModel()
        if LocalPlayer():GetEyeTrace().Entity == self then
            local pos = self:GetPos() + Vector(0, 0, 52)
            local ang = Angle(0, LocalPlayer():EyeAngles().y - 90, 90)
            cam.Start3D2D(pos, ang, 0.1)
                local state = self:GetLeaks() > 0 and ("LEAKING x" .. self:GetLeaks()) or (self:GetOpen() and "OPEN" or "CLOSED")
                draw.SimpleText(string.format("%s  %d%%  %s", self:GetGasName(), self:GetContents() / CAPACITY * 100, state),
                    "DermaLarge", 0, 0, self:GetLeaks() > 0 and Color(255, 120, 80) or color_white, TEXT_ALIGN_CENTER)
            cam.End3D2D()
        end
    end
    return
end

function ENT:Initialize()
    self:SetModel("models/aether/gas_cylinder.mdl")
    self:PhysicsInit(SOLID_VPHYSICS)
    self:SetMoveType(MOVETYPE_VPHYSICS)
    self:SetSolid(SOLID_VPHYSICS)
    self:SetUseType(SIMPLE_USE)
    local phys = self:GetPhysicsObject()
    if IsValid(phys) then phys:Wake() end
    if self:GetGasName() == "" then self:SetGasName(self.InitGas or "chlorine") end
    if self.InitPlain then self:SetPlain(true) end
    self:UpdateSkin()
    self:SetContents(CAPACITY)
    self.LeakList = {}
end

local function Flammable(self)
    local def = AetherGas.GetGas(self:GetGasName())
    return def ~= nil and def.flammable
end

--- Пробоина в точке hitPos: струя газа по нормали от оси баллона, тяга в обратную сторону.
function ENT:AddLeak(hitPos)
    if #self.LeakList >= MAX_LEAKS or self:GetContents() <= 0 or self.Exploded then return end
    local lp = self:WorldToLocal(hitPos)
    local n = Vector(lp.x, lp.y, 0)          -- нормаль боковой стенки (ось баллона — Z)
    if n:LengthSqr() < 0.01 then n = Vector(1, 0, 0) end
    n:Normalize()
    local leak = { pos = lp, normal = n }
    leak.source = AetherGas.Solver.AddSource(self:GetGasName(), lp + n * 1.5, LEAK_RATE, 0, nil, n * 300, self)
    self.LeakList[#self.LeakList + 1] = leak
    self:SetLeaks(#self.LeakList)
    if not self.LeakHiss then
        self.LeakHiss = CreateSound(self, "ambient/gas/steam2.wav")
        self.LeakHiss:PlayEx(0.8, 115)
    end
    self:EmitSound("physics/metal/metal_canister_impact_hard" .. math.random(1, 3) .. ".wav", 75, 110)
end

function ENT:StopLeaks()
    for _, leak in ipairs(self.LeakList or {}) do AetherGas.Solver.StopSource(leak.source) end
    self.LeakList = {}
    self:SetLeaks(0)
    if self.LeakHiss then self.LeakHiss:FadeOut(0.5) self.LeakHiss = nil end
end

--- Разрыв: весь остаток газа — облаком; горючий газ взрывается (поджиг через тик, облако успевает появиться).
function ENT:Burst(explode, attacker)
    if self.Exploded then return end
    self.Exploded = true
    local pos = self:WorldSpaceCenter()
    self:StopLeaks()
    if self.SourceId then AetherGas.Solver.StopSource(self.SourceId) self.SourceId = nil end
    local amount = self:GetContents()
    if amount > 0 then AetherGas.Solver.PuffAt(self:GetGasName(), pos, amount, nil, Vector(0, 0, 60), 2) end
    if explode then
        local ed = EffectData()
        ed:SetOrigin(pos)
        util.Effect("Explosion", ed, true, true)
        util.BlastDamage(self, IsValid(attacker) and attacker or self, pos, 240, 110)
        timer.Simple(0.15, function() AetherGas.Solver.BlastAt(pos, 300, 1100) end)
    else
        self:EmitSound("physics/metal/metal_barrel_impact_hard" .. math.random(1, 3) .. ".wav", 90, 80)
        AetherGas.Solver.BlastAt(pos, 200, 700, true)
    end
    self:Remove()
end

local IGNITING = bit.bor(DMG_BURN, DMG_SHOCK, DMG_ENERGYBEAM, DMG_PLASMA, DMG_DISSOLVE, DMG_SLOWBURN)
local PIERCING = bit.bor(DMG_BULLET, DMG_BUCKSHOT, DMG_SNIPER, DMG_NEVERGIB, DMG_SLASH, DMG_CLUB, DMG_AIRBOAT)

function ENT:OnTakeDamage(dmg)
    if self.Exploded or self:GetContents() <= 0 then return end
    local flammable = Flammable(self)
    local ignites = dmg:IsExplosionDamage() or bit.band(dmg:GetDamageType(), IGNITING) ~= 0
    local bigCaliber = dmg:IsBulletDamage() and dmg:GetDamage() > BIG_CALIBER and not dmg:IsDamageType(DMG_NEVERGIB)
    if flammable and (ignites or bigCaliber) then
        self:Burst(true, dmg:GetAttacker())
        return
    end
    if dmg:IsExplosionDamage() then   -- негорючий газ: разрыв
        self:Burst(false)
        return
    end
    local pierce = bit.band(dmg:GetDamageType(), PIERCING) ~= 0 or (dmg:IsDamageType(DMG_CRUSH) and dmg:GetDamage() > 80)
    if pierce and (not dmg:IsDamageType(DMG_CLUB) or dmg:GetDamage() > 20) then
        local pos = dmg:GetDamagePosition()
        if pos:IsZero() then pos = self:WorldSpaceCenter() + VectorRand() * 3 end
        self:AddLeak(pos)
    end
end

function ENT:SetValve(open)
    if open == self:GetOpen() then return end
    self:SetOpen(open)
    if open and self:GetContents() > 0 then
        local hose = self.Hose
        if IsValid(hose) then   -- газ идёт по шлангу и выходит из наконечника
            self.SourceId = AetherGas.Solver.AddSource(self:GetGasName(), Vector(4.6, 0, 0), RATE, 0, nil, Vector(120, 0, 0), hose)
        else
            local up = Vector(2.8, 0, 41.5)   -- выход вентиля
            self.SourceId = AetherGas.Solver.AddSource(self:GetGasName(), up, RATE, 0, nil, Vector(60, 0, 10), self)
        end
        self.Hiss = CreateSound(self, "ambient/gas/cannister_loop.wav")
        self.Hiss:PlayEx(0.5, 95)
        self:EmitSound("buttons/lever7.wav")
    else
        if self.SourceId then AetherGas.Solver.StopSource(self.SourceId) end
        self.SourceId = nil
        if self.Hiss then self.Hiss:Stop() end
        self:EmitSound("buttons/lever8.wav")
    end
end

--- Подключить/отключить шланг (вызывает тулган). Открытый вентиль переключается на новый выход.
function ENT:SetHose(nozzle)
    local wasOpen = self:GetOpen()
    if wasOpen then self:SetValve(false) end
    self.Hose = IsValid(nozzle) and nozzle or nil
    if IsValid(nozzle) then
        nozzle.Canister = self
        nozzle:SetCanister(self)
    end
    if wasOpen then self:SetValve(true) end
end

function ENT:Use(activator)
    if IsValid(activator) and activator:IsPlayer() then self:SetValve(not self:GetOpen()) end
end

function ENT:Think()
    local dt = 0.1
    local drain = (self:GetOpen() and RATE or 0) + LEAK_RATE * #self.LeakList
    if drain > 0 then
        local left = math.max(0, self:GetContents() - drain * dt)
        self:SetContents(left)
        if left <= 0 then
            if self:GetOpen() then self:SetValve(false) end
            self:StopLeaks()
        end
    end
    -- реактивная тяга пробоин: струя наружу толкает баллон внутрь
    if #self.LeakList > 0 then
        local phys = self:GetPhysicsObject()
        if IsValid(phys) then
            local o = self:GetPos()
            for _, leak in ipairs(self.LeakList) do
                local wn = self:LocalToWorld(leak.normal) - o
                phys:ApplyForceOffset(-wn * THRUST * dt * phys:GetMass(), self:LocalToWorld(leak.pos))
            end
        end
    end
    -- в огне: горючий взрывается через 2 с, негорючий травит через предохранительный клапан
    if self:IsOnFire() and self:GetContents() > 0 then
        self.FireSince = self.FireSince or CurTime()
        if Flammable(self) then
            if CurTime() - self.FireSince > 2 then self:Burst(true) return end
        elseif #self.LeakList == 0 then
            self:AddLeak(self:LocalToWorld(Vector(2.8, 0, 41.5)))
        end
    else
        self.FireSince = nil
    end
    self:NextThink(CurTime() + dt)
    return true
end

function ENT:OnRemove()
    if self.Hiss then self.Hiss:Stop() end
    if self.LeakHiss then self.LeakHiss:Stop() end
    if self.SourceId then AetherGas.Solver.StopSource(self.SourceId) end
    for _, leak in ipairs(self.LeakList or {}) do AetherGas.Solver.StopSource(leak.source) end
end
