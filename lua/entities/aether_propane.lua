-- lua/entities/aether_propane.lua
--[[
    Пробиваемый баллон с горючим газом (метан). Пуля пробивает стенку: из пробоины бьёт струя газа,
    а реакция струи толкает баллон (F = −n·THRUST в точке пробоины, ApplyForceOffset — баллон
    закручивается и летает). Огонь, взрыв или критический урон — подрыв: весь остаток выбрасывается
    облаком и поджигается, дальше работает цепная детонация солвера.
]]
AddCSLuaFile()

ENT.Type      = "anim"
ENT.Base      = "base_anim"
ENT.PrintName = "Propane Tank"
ENT.Author    = "Aether"
ENT.Category  = "Aether Gas"
ENT.Spawnable = true

local CAPACITY  = 80
local LEAK_RATE = 8      -- концентрация/с из одной пробоины
local THRUST    = 2600   -- сила реакции струи
local MAX_HP    = 60

if CLIENT then return end

function ENT:Initialize()
    self:SetModel("models/aether/propane_tank.mdl")
    self:PhysicsInit(SOLID_VPHYSICS)
    self:SetMoveType(MOVETYPE_VPHYSICS)
    self:SetSolid(SOLID_VPHYSICS)
    local phys = self:GetPhysicsObject()
    if IsValid(phys) then phys:Wake() end
    self.Contents = CAPACITY
    self.HP = MAX_HP
    self.Leaks = {}
end

function ENT:AddLeak(hitPos)
    if #self.Leaks >= 3 or self.Contents <= 0 then return end
    local localPos = self:WorldToLocal(hitPos)
    local n = localPos:GetNormalized()
    local leak = { pos = localPos, normal = n }
    leak.source = AetherGas.Solver.AddSource("methane", localPos, LEAK_RATE, 0, nil, n * 250, self)
    self.Leaks[#self.Leaks + 1] = leak
    if not self.Hiss then
        self.Hiss = CreateSound(self, "ambient/gas/steam2.wav")
        self.Hiss:PlayEx(0.8, 120)
    end
end

function ENT:Detonate()
    if self.Exploded then return end
    self.Exploded = true
    local pos = self:WorldSpaceCenter()
    for _, leak in ipairs(self.Leaks) do AetherGas.Solver.StopSource(leak.source) end
    if self.Contents > 0 then
        -- Весь остаток — облаком за доли секунды, поджиг на следующем тике (облако успевает появиться)
        AetherGas.Solver.AddSource("methane", pos, self.Contents * 6, 0.25, nil, Vector(0, 0, 80))
    end
    local ed = EffectData()
    ed:SetOrigin(pos)
    util.Effect("Explosion", ed, true, true)
    util.BlastDamage(self, self, pos, 220, 90)
    timer.Simple(0.3, function() AetherGas.Solver.BlastAt(pos, 260, 900) end)
    self:Remove()
end

function ENT:OnTakeDamage(dmg)
    if self.Exploded then return end
    if dmg:IsDamageType(DMG_BURN) or dmg:IsExplosionDamage() then
        self:Detonate()
        return
    end
    self.HP = self.HP - dmg:GetDamage()
    if dmg:IsBulletDamage() then self:AddLeak(dmg:GetDamagePosition()) end
    if self.HP <= 0 then self:Detonate() end
end

function ENT:Think()
    if #self.Leaks > 0 then
        local dt = 0.05
        self.Contents = self.Contents - LEAK_RATE * #self.Leaks * dt
        local phys = self:GetPhysicsObject()
        if IsValid(phys) then
            for _, leak in ipairs(self.Leaks) do
                local wpos = self:LocalToWorld(leak.pos)
                local wnorm = self:LocalToWorld(leak.normal) - self:GetPos()
                phys:ApplyForceOffset(-wnorm * THRUST * dt * phys:GetMass(), wpos)
            end
        end
        if self.Contents <= 0 then
            for _, leak in ipairs(self.Leaks) do AetherGas.Solver.StopSource(leak.source) end
            self.Leaks = {}
            if self.Hiss then self.Hiss:FadeOut(0.5) end
        end
    end
    if self:IsOnFire() then self:Detonate() return end
    self:NextThink(CurTime() + 0.05)
    return true
end

function ENT:OnRemove()
    if self.Hiss then self.Hiss:Stop() end
    for _, leak in ipairs(self.Leaks or {}) do AetherGas.Solver.StopSource(leak.source) end
end
