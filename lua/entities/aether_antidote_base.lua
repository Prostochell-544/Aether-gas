-- lua/entities/aether_antidote_base.lua
--[[
    База предметов-антидотов (aether_atropine, aether_decon, aether_eyewash, aether_oxygen).
    «E» — применить на себя: AetherGas.ApplyAntidote (sv_network.lua). Подействовал — предмет тратится и игрок
    получает подсказку; лечить нечего — подсказка «нечего лечить», предмет остаётся (атропин — исключение:
    его можно уколоть заранее, профилактика).
    Наследник задаёт ENT.AntidoteKind, ENT.Model, ENT.PrintName, ENT.HintKey.
]]
AddCSLuaFile()

ENT.Type      = "anim"
ENT.Base      = "base_anim"
ENT.PrintName = "Antidote"
ENT.Author    = "Aether"
ENT.Category  = "Aether Gas"
ENT.Spawnable = false

-- Виды: 1 СССР (скин 0), 2 НАТО (скин 1)
ENT.LookStyles = { 1, 2 }

function ENT:SetupDataTables()
    self:NetworkVar("Int", 0, "Style")
end

function ENT:UpdateLook()
    self:SetSkin(self:GetStyle() == 2 and 1 or 0)
end

if CLIENT then return end

function ENT:Initialize()
    self:SetModel(self.Model)
    if self:GetStyle() == 0 then self:SetStyle(AetherGas.PickItemLook(self.LookStyles)) end
    self:UpdateLook()
    self:PhysicsInit(SOLID_VPHYSICS)
    self:SetMoveType(MOVETYPE_VPHYSICS)
    self:SetSolid(SOLID_VPHYSICS)
    self:SetUseType(SIMPLE_USE)
    local phys = self:GetPhysicsObject()
    if IsValid(phys) then phys:Wake() end
end

function ENT:Use(activator)
    if not IsValid(activator) or not activator:IsPlayer() or not activator:Alive() then return end
    if AetherGas.ApplyAntidote(activator, self.AntidoteKind) then
        AetherGas.Notify(activator, 1, self.HintKey)
        self:Remove()
    else
        AetherGas.Notify(activator, 2, "hint.antidote_nothing")
    end
end
