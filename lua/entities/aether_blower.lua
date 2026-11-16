-- lua/entities/aether_blower.lua
-- Воздуходувка: «E» вкл/выкл. Струя вдоль «вперёд» (+X модели, сторона решётки) толкает газ на ~520 юнитов,
-- не уничтожая его.
AddCSLuaFile()

ENT.Type      = "anim"
ENT.Base      = "aether_fan"
ENT.PrintName = "Blower Fan"
ENT.Author    = "Aether"
ENT.Category  = "Aether Gas"
ENT.Spawnable = true
ENT.AdminOnly = false

local STRENGTH, RADIUS = 1400, 120

if CLIENT then return end

function ENT:Initialize()
    self.BaseClass.Initialize(self)
    self:SetSkin(1)
end

function ENT:SetPower(on)
    if on == self:GetOn() then return end
    self:SetOn(on)
    if on then
        self.SinkId = AetherGas.Solver.AddBlower(self, Vector(6, 0, 15), STRENGTH, RADIUS)
        self.Hum = CreateSound(self, "ambient/machines/turbine_loop_1.wav")
        self.Hum:PlayEx(0.45, 115)
    else
        if self.SinkId then AetherGas.Solver.StopSource(self.SinkId) end
        self.SinkId = nil
        if self.Hum then self.Hum:Stop() end
    end
    self:EmitSound("buttons/button1.wav")
end
