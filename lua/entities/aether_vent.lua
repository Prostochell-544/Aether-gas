-- lua/entities/aether_vent.lua
--[[
    Решётка воздуховода. Впуск забирает газ перед собой (радиус 110) и по трубе выдаёт его из выпуска,
    к которому подключён тулганом «Gas Duct / Hose». «E» на впуске — вкл/выкл. Выпуск пассивный (скин 1).
]]
AddCSLuaFile()

ENT.Type      = "anim"
ENT.Base      = "base_anim"
ENT.PrintName = "Duct Vent"
ENT.Author    = "Aether"
ENT.Category  = "Aether Gas"
ENT.Spawnable = true

local RATE, RADIUS = 2.5, 110

function ENT:SetupDataTables()
    self:NetworkVar("Bool", 0, "On")
    self:NetworkVar("Bool", 1, "IsOutlet")
    self:NetworkVar("Entity", 0, "Link")
end

if CLIENT then return end

function ENT:Initialize()
    self:SetModel("models/aether/gas_vent.mdl")
    self:PhysicsInit(SOLID_VPHYSICS)
    self:SetMoveType(MOVETYPE_VPHYSICS)
    self:SetSolid(SOLID_VPHYSICS)
    self:SetUseType(SIMPLE_USE)
    self:SetSkin(self:GetIsOutlet() and 1 or 0)
    local phys = self:GetPhysicsObject()
    if IsValid(phys) then phys:Wake() end
end

function ENT:SetActive(on)
    if self:GetIsOutlet() then return end
    if on and not IsValid(self:GetLink()) then on = false end
    if on == self:GetOn() and (on == (self.DuctId ~= nil)) then return end
    self:SetOn(on)
    if self.DuctId then AetherGas.Solver.StopSource(self.DuctId) end
    self.DuctId = nil
    if on then
        self.DuctId = AetherGas.Solver.AddDuct(self, self:GetLink(), Vector(20, 0, 0), RATE, RADIUS)
        self:EmitSound("buttons/button3.wav")
    else
        self:EmitSound("buttons/button2.wav")
    end
end

function ENT:Use(activator)
    if IsValid(activator) and activator:IsPlayer() then
        if self:GetIsOutlet() then
            local inlet = self.Inlet
            if IsValid(inlet) then inlet:SetActive(not inlet:GetOn()) end
        else
            self:SetActive(not self:GetOn())
        end
    end
end

function ENT:Think()
    -- выпуск удалили — впуск выключается
    if self:GetOn() and not IsValid(self:GetLink()) then self:SetActive(false) end
    self:NextThink(CurTime() + 0.5)
    return true
end

function ENT:OnRemove()
    if self.DuctId then AetherGas.Solver.StopSource(self.DuctId) end
end
