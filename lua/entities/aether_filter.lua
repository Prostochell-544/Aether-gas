-- lua/entities/aether_filter.lua
--[[
    Фильтрующая коробка для противогаза Aether. «E»:
      • фильтра в маске меньше половины — коробка сразу вкручивается (старая выбрасывается);
      • иначе — в запас (не больше AetherGas.MAX_SPARE_FILTERS); когда фильтр в маске кончится,
        запасной вкручивается сам (sv_network.lua).
    Без противогаза коробку не поднять (некуда вкрутить).
]]
AddCSLuaFile()

ENT.Type      = "anim"
ENT.Base      = "base_anim"
ENT.PrintName = "Gas Mask Filter"
ENT.Author    = "Aether"
ENT.Category  = "Aether Gas"
ENT.Spawnable = true

if CLIENT then return end

function ENT:Initialize()
    self:SetModel("models/aether/gas_filter.mdl")
    self:PhysicsInit(SOLID_VPHYSICS)
    self:SetMoveType(MOVETYPE_VPHYSICS)
    self:SetSolid(SOLID_VPHYSICS)
    self:SetUseType(SIMPLE_USE)
    local phys = self:GetPhysicsObject()
    if IsValid(phys) then phys:Wake() end
end

function ENT:Use(activator)
    if not IsValid(activator) or not activator:IsPlayer() then return end
    if AetherGas.AddFilter(activator) then self:Remove() end
end
