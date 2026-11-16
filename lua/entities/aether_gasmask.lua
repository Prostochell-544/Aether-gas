-- lua/entities/aether_gasmask.lua
-- Противогаз: «E» — подобрать и надеть (фильтр переносится). Дальше E+R / «!mask» — надеть/снять,
-- aether_mask_drop — выбросить с остатком фильтра.
AddCSLuaFile()

ENT.Type      = "anim"
ENT.Base      = "base_anim"
ENT.PrintName = "Gas Mask"
ENT.Author    = "Aether"
ENT.Category  = "Aether Gas"
ENT.Spawnable = true

function ENT:SetupDataTables()
    self:NetworkVar("Float", 0, "Filter")
end

if CLIENT then return end

function ENT:Initialize()
    self:SetModel("models/aether/gasmask.mdl")
    self:PhysicsInit(SOLID_VPHYSICS)
    self:SetMoveType(MOVETYPE_VPHYSICS)
    self:SetSolid(SOLID_VPHYSICS)
    self:SetUseType(SIMPLE_USE)
    local phys = self:GetPhysicsObject()
    if IsValid(phys) then phys:Wake() end
    if self:GetFilter() <= 0 then self:SetFilter(AetherGas.CVar.MaskFilter:GetFloat()) end
end

function ENT:Use(activator)
    if not IsValid(activator) or not activator:IsPlayer() or AetherGas.OwnsMask(activator) then return end
    if AetherGas.GiveMask(activator, self:GetFilter()) then self:Remove() end
end
