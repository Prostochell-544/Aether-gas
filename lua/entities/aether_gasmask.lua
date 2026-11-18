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

-- «E»: нет маски — подобрать и надеть; маска уже есть — забрать фильтр посвежее (старый остаётся в лежащей
-- маске) и надеть свою.
function ENT:Use(activator)
    if not IsValid(activator) or not activator:IsPlayer() then return end
    if not AetherGas.OwnsMask(activator) then
        if AetherGas.GiveMask(activator, self:GetFilter()) then self:Remove() end
        return
    end
    local mine = activator:GetNW2Float("AetherFilter", 0)
    if self:GetFilter() > mine + 1 then
        activator:SetNW2Float("AetherFilter", self:GetFilter())
        self:SetFilter(mine)
        activator:EmitSound("items/ammopickup.wav", 60, 90)
        activator:ChatPrint("[Aether] Swapped in the fresher filter from this mask.")
        if mine <= 1 then self:Remove() end
    end
    if not AetherGas.HasMask(activator) then AetherGas.ToggleMask(activator) end
end
