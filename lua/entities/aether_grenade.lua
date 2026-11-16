-- lua/entities/aether_grenade.lua
-- Газовая граната: через FUSE секунд выпускает газ, источник привязан к гранате (катится — облако тянется).
AddCSLuaFile()

ENT.Type      = "anim"
ENT.Base      = "base_anim"
ENT.PrintName = "Gas Grenade"
ENT.Author    = "Aether"
ENT.Category  = "Aether Gas"
ENT.Spawnable = true

local FUSE = 1.5

function ENT:SetupDataTables()
    self:NetworkVar("String", 0, "GasName")
    self:NetworkVar("Bool", 0, "Emitting")
end

if CLIENT then return end

function ENT:Initialize()
    self:SetModel("models/aether/gas_grenade.mdl")
    self:PhysicsInit(SOLID_VPHYSICS)
    self:SetMoveType(MOVETYPE_VPHYSICS)
    self:SetSolid(SOLID_VPHYSICS)
    self:SetCollisionGroup(COLLISION_GROUP_WEAPON)
    local phys = self:GetPhysicsObject()
    if IsValid(phys) then phys:Wake() end
    if self:GetGasName() == "" then self:SetGasName("smoke") end
    self:SetSkin(AetherGas.GasSkin(self:GetGasName()))
    self.FuseAt = CurTime() + FUSE
end

function ENT:Think()
    local now = CurTime()
    if not self:GetEmitting() and now >= self.FuseAt then
        local name = self:GetGasName()
        local def = AetherGas.GetGas(name) or AetherGas.GetGas("smoke")
        local p = def.grenade   -- скорость (концентрация/с), длительность (с), струя вверх — из реестра
        self.SourceId = AetherGas.Solver.AddSource(name, Vector(0, 0, 7.4), p[1], p[2], nil, Vector(0, 0, p[3]), self)
        self:SetEmitting(true)
        self.EndAt = now + p[2]
        self.Hiss = CreateSound(self, "ambient/gas/cannister_loop.wav")
        self.Hiss:PlayEx(0.6, 110)
    elseif self:GetEmitting() and now >= self.EndAt then
        if self.Hiss then self.Hiss:FadeOut(1) end
        SafeRemoveEntityDelayed(self, 8)
        self.EndAt = math.huge
    end
    self:NextThink(now + 0.1)
    return true
end

function ENT:OnRemove()
    if self.Hiss then self.Hiss:Stop() end
    if self.SourceId then AetherGas.Solver.StopSource(self.SourceId) end
end
