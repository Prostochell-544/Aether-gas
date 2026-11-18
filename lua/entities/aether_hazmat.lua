-- lua/entities/aether_hazmat.lua
--[[
    Костюм химзащиты (CBRN) с изолирующим дыхательным аппаратом. «E» — надеть.
    Защищает целиком: дыхание и кожу от всех газов Aether (зарин и иприт тоже), от удушья (CO, CO2, азот);
    от ожога паром — наполовину. Движения на 10 % медленнее. Снять (выпадает на землю): «!suit» в чат,
    aether_suit_drop, при смерти выпадает сам. Для GBombs ставит ply.hazsuited (их газы тоже не действуют).
]]
AddCSLuaFile()

ENT.Type      = "anim"
ENT.Base      = "base_anim"
ENT.PrintName = "Hazmat Suit"
ENT.Author    = "Aether"
ENT.Category  = "Aether Gas"
ENT.Spawnable = true

if CLIENT then return end

function ENT:Initialize()
    self:SetModel("models/aether/hazmat_suit.mdl")
    self:PhysicsInit(SOLID_VPHYSICS)
    self:SetMoveType(MOVETYPE_VPHYSICS)
    self:SetSolid(SOLID_VPHYSICS)
    self:SetUseType(SIMPLE_USE)
    local phys = self:GetPhysicsObject()
    if IsValid(phys) then phys:Wake() end
end

function ENT:Use(activator)
    if not IsValid(activator) or not activator:IsPlayer() then return end
    if AetherGas.WearSuit(activator) then self:Remove() end
end
