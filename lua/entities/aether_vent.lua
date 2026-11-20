-- lua/entities/aether_vent.lua
--[[
    Решётка воздуховода. Впуск забирает газ перед собой (радиус 110) и по трубе выдаёт его из выпуска,
    к которому подключён тулганом «Gas Duct / Hose». «E» на впуске — вкл/выкл. Выпуск пассивный (скин 1).
    К одному выпуску можно подключить несколько впусков (каждый — свой поток в солвере); «E» на выпуске
    включает или выключает их все. Выпуск хранит множество впусков self.Inlets ([ent] = true), On выпуска
    показывает, работает ли хоть один.
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
    self:NetworkVar("Int", 0, "Style")
end

-- Виды: 1 СССР, 2 НАТО, 4 классика. Скины: классика 0/1, СССР 2/3, НАТО 4/5 (+1 — выпуск)
ENT.LookStyles = { 1, 2, 4 }
local LOOK_BASE = { [1] = 2, [2] = 4, [4] = 0 }
function ENT:UpdateLook()
    self:SetSkin((LOOK_BASE[self:GetStyle()] or 0) + (self:GetIsOutlet() and 1 or 0))
end

if CLIENT then return end

function ENT:Initialize()
    self:SetModel("models/aether/gas_vent.mdl")
    self:PhysicsInit(SOLID_VPHYSICS)
    self:SetMoveType(MOVETYPE_VPHYSICS)
    self:SetSolid(SOLID_VPHYSICS)
    self:SetUseType(SIMPLE_USE)
    if self:GetStyle() == 0 then self:SetStyle(AetherGas.PickItemLook(self.LookStyles)) end
    self:UpdateLook()
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

--- Впуски, подключённые к этому выпуску (недействительные и переподключённые к другому выпуску отсеиваются).
function ENT:GetInlets()
    local out = {}
    if not self.Inlets then return out end
    for inlet in pairs(self.Inlets) do
        if IsValid(inlet) and inlet:GetLink() == self then out[#out + 1] = inlet else self.Inlets[inlet] = nil end
    end
    return out
end

function ENT:AddInlet(inlet)
    self.Inlets = self.Inlets or {}
    self.Inlets[inlet] = true
end

--- Выпуск: включить/выключить все свои впуски. Впуск: себя.
function ENT:SetAllActive(on)
    if not self:GetIsOutlet() then self:SetActive(on) return end
    local list = self:GetInlets()
    for i = 1, #list do list[i]:SetActive(on) end
    self:SetOn(on and #list > 0)
end

function ENT:Use(activator)
    if IsValid(activator) and activator:IsPlayer() then
        if self:GetIsOutlet() then
            -- хоть один работает — выключить все, иначе включить все
            local list, any = self:GetInlets(), false
            for i = 1, #list do if list[i]:GetOn() then any = true break end end
            self:SetAllActive(not any)
        else
            self:SetActive(not self:GetOn())
        end
    end
end

function ENT:Think()
    if self:GetIsOutlet() then
        -- On выпуска = работает хоть один впуск (Wiremod, «Valve Group»)
        local list, any = self:GetInlets(), false
        for i = 1, #list do if list[i]:GetOn() then any = true break end end
        if self:GetOn() ~= any then self:SetOn(any) end
    elseif self:GetOn() and not IsValid(self:GetLink()) then
        self:SetActive(false)   -- выпуск удалили — впуск выключается
    end
    self:NextThink(CurTime() + 0.5)
    return true
end

function ENT:OnRemove()
    if self.DuctId then AetherGas.Solver.StopSource(self.DuctId) end
end
