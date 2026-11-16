-- lua/entities/aether_hose_nozzle.lua
-- Наконечник шланга: создаётся тулганом «Gas Duct / Hose»; газ баллона выходит отсюда вдоль +X.
AddCSLuaFile()

ENT.Type      = "anim"
ENT.Base      = "base_anim"
ENT.PrintName = "Hose Nozzle"
ENT.Author    = "Aether"
ENT.Category  = "Aether Gas"
ENT.Spawnable = false

function ENT:SetupDataTables()
    self:NetworkVar("Entity", 0, "Canister")
end

if CLIENT then
    function ENT:Draw()
        self:DrawModel()
        local can = self:GetCanister()
        if IsValid(can) and LocalPlayer():GetEyeTrace().Entity == self then
            local pos = self:GetPos() + Vector(0, 0, 8)
            local ang = Angle(0, LocalPlayer():EyeAngles().y - 90, 90)
            cam.Start3D2D(pos, ang, 0.08)
                draw.SimpleText(string.format("HOSE: %s  %s  [E]", can:GetGasName(), can:GetOpen() and "OPEN" or "CLOSED"),
                    "DermaLarge", 0, 0, color_white, TEXT_ALIGN_CENTER)
            cam.End3D2D()
        end
    end
    return
end

function ENT:Initialize()
    self:SetModel("models/aether/hose_nozzle.mdl")
    self:PhysicsInit(SOLID_VPHYSICS)
    self:SetMoveType(MOVETYPE_VPHYSICS)
    self:SetSolid(SOLID_VPHYSICS)
    self:SetUseType(SIMPLE_USE)
    local phys = self:GetPhysicsObject()
    if IsValid(phys) then phys:Wake() end
end

-- «E» на наконечнике открывает/закрывает вентиль баллона на другом конце шланга
function ENT:Use(activator)
    local can = self.Canister
    if IsValid(can) and IsValid(activator) and activator:IsPlayer() then can:SetValve(not can:GetOpen()) end
end

function ENT:OnRemove()
    local can = self.Canister
    if IsValid(can) and can.SetHose then can:SetHose(nil) end
end
