-- lua/entities/aether_emitter.lua
-- Настраиваемый эмиттер для тулгана: газ, скорость выброса; «E» вкл/выкл, работает бессрочно.
AddCSLuaFile()

ENT.Type      = "anim"
ENT.Base      = "base_anim"
ENT.PrintName = "Gas Emitter"
ENT.Author    = "Aether"
ENT.Category  = "Aether Gas"
ENT.Spawnable = false

function ENT:SetupDataTables()
    self:NetworkVar("String", 0, "GasName")
    self:NetworkVar("Float", 0, "Rate")
    self:NetworkVar("Bool", 0, "On")
end

if CLIENT then return end

function ENT:Initialize()
    self:SetModel("models/aether/gas_emitter.mdl")
    self:PhysicsInit(SOLID_VPHYSICS)
    self:SetMoveType(MOVETYPE_VPHYSICS)
    self:SetSolid(SOLID_VPHYSICS)
    self:SetUseType(SIMPLE_USE)
    if self:GetGasName() == "" then self:SetGasName("smoke") end
    if self:GetRate() <= 0 then self:SetRate(5) end
end

function ENT:SetActive(on)
    if on == self:GetOn() then return end
    self:SetOn(on)
    if self.SourceId then AetherGas.Solver.StopSource(self.SourceId) end
    self.SourceId = nil
    if on then
        self.SourceId = AetherGas.Solver.AddSource(self:GetGasName(), Vector(0, 0, 19), self:GetRate(), 0, nil, Vector(0, 0, 40), self)
    end
    self:EmitSound(on and "buttons/button3.wav" or "buttons/button2.wav")
end

function ENT:Use(activator)
    if IsValid(activator) and activator:IsPlayer() then self:SetActive(not self:GetOn()) end
end

function ENT:OnRemove()
    if self.SourceId then AetherGas.Solver.StopSource(self.SourceId) end
end
