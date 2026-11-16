-- lua/entities/aether_fan.lua
-- Вытяжной вентилятор: «E» вкл/выкл. Сток газа перед лопастями: убирает газ и тянет облако к себе.
AddCSLuaFile()

ENT.Type      = "anim"
ENT.Base      = "base_anim"
ENT.PrintName = "Exhaust Fan (Admin, destroys gas)"
ENT.Author    = "Aether"
ENT.Category  = "Aether Gas"
ENT.Spawnable = true
ENT.AdminOnly = true

local RADIUS = 160
local RATE   = 3

function ENT:SetupDataTables()
    self:NetworkVar("Bool", 0, "On")
end

if CLIENT then
    -- Лопасти — отдельная кость «blades» (ось X модели): вращаем, пока вентилятор включён.
    function ENT:Think()
        local bone = self.BladeBone or self:LookupBone("blades")
        self.BladeBone = bone
        if bone then
            self.Spin = (self.Spin or 0) + (self:GetOn() and 900 or 0) * FrameTime()
            self:ManipulateBoneAngles(bone, Angle(0, 0, self.Spin % 360))
        end
        self:SetNextClientThink(CurTime())
        return true
    end
    return
end

function ENT:Initialize()
    self:SetModel("models/aether/exhaust_fan.mdl")
    self:PhysicsInit(SOLID_VPHYSICS)
    self:SetMoveType(MOVETYPE_VPHYSICS)
    self:SetSolid(SOLID_VPHYSICS)
    self:SetUseType(SIMPLE_USE)
    local phys = self:GetPhysicsObject()
    if IsValid(phys) then phys:Wake() end
end

function ENT:SetPower(on)
    if on == self:GetOn() then return end
    self:SetOn(on)
    if on then
        self.SinkId = AetherGas.Solver.AddSink(Vector(40, 0, 15), RADIUS, RATE, 0, self)
        self.Hum = CreateSound(self, "ambient/machines/turbine_loop_1.wav")
        self.Hum:PlayEx(0.5, 100)
    else
        if self.SinkId then AetherGas.Solver.StopSource(self.SinkId) end
        self.SinkId = nil
        if self.Hum then self.Hum:Stop() end
    end
    self:EmitSound("buttons/button1.wav")
end

function ENT:Use(activator)
    if IsValid(activator) and activator:IsPlayer() then self:SetPower(not self:GetOn()) end
end

function ENT:OnRemove()
    if self.Hum then self.Hum:Stop() end
    if self.SinkId then AetherGas.Solver.StopSource(self.SinkId) end
end
