-- lua/entities/aether_canister.lua
-- Газовый баллон: «E» открывает/закрывает вентиль, запас конечен. Газ — keyvalue «gas» (в спавн-меню по баллону
-- на каждый газ), меню C → Gas type / Unmarked (old) look, тулган «Gas Duct / Hose» — шланг.
-- Keyvalue «plain» 1 — старый баллон без надписей (свой скин, газ внутри любой).
AddCSLuaFile()

ENT.Type      = "anim"
ENT.Base      = "base_anim"
ENT.PrintName = "Gas Cylinder"
ENT.Author    = "Aether"
ENT.Category  = "Aether Gas"
ENT.Spawnable = false   -- в спавн-меню — пресеты ниже (по одному на газ)

-- Пресеты спавн-меню: тот же класс, газ через KeyValues; иконка materials/entities/aether_cylinder_<газ>.png
for i = 1, #AetherGas.BaseGases do
    local name = AetherGas.BaseGases[i]
    local def = AetherGas.GetGas(name)
    if def then
        list.Set("SpawnableEntities", "aether_cylinder_" .. name, {
            PrintName = "Cylinder: " .. def.printName,
            ClassName = "aether_canister",
            Category  = "Aether Gas",
            KeyValues = { gas = name },
            DropToFloor = true,
            IconOverride = "entities/aether_cylinder_" .. name .. ".png",
        })
    end
end
list.Set("SpawnableEntities", "aether_cylinder_plain", {
    PrintName = "Cylinder: Unmarked (old)",
    ClassName = "aether_canister",
    Category  = "Aether Gas",
    KeyValues = { gas = "smoke", plain = "1" },
    DropToFloor = true,
    IconOverride = "entities/aether_cylinder_plain.png",
})

function ENT:KeyValue(key, value)
    key = string.lower(key)
    if key == "gas" and AetherGas.GetGas(value) then self.InitGas = value end
    if key == "plain" then self.InitPlain = tobool(value) end
end

local CAPACITY = 120   -- единиц концентрации на весь баллон
local RATE     = 5     -- концентрация/с из вентиля

function ENT:SetupDataTables()
    self:NetworkVar("String", 0, "GasName")
    self:NetworkVar("Bool", 0, "Open")
    self:NetworkVar("Float", 0, "Contents")
    self:NetworkVar("Bool", 1, "Plain")
end

--- Скин: без надписей — отдельный, иначе по газу.
function ENT:UpdateSkin()
    self:SetSkin(self:GetPlain() and AetherGas.PLAIN_CYLINDER_SKIN or AetherGas.GasSkin(self:GetGasName()))
end

if CLIENT then
    function ENT:Draw()
        self:DrawModel()
        if LocalPlayer():GetEyeTrace().Entity == self then
            local pos = self:GetPos() + Vector(0, 0, 52)
            local ang = Angle(0, LocalPlayer():EyeAngles().y - 90, 90)
            cam.Start3D2D(pos, ang, 0.1)
                draw.SimpleText(string.format("%s  %d%%  %s", self:GetGasName(), self:GetContents() / CAPACITY * 100,
                    self:GetOpen() and "OPEN" or "CLOSED"), "DermaLarge", 0, 0, color_white, TEXT_ALIGN_CENTER)
            cam.End3D2D()
        end
    end
    return
end

function ENT:Initialize()
    self:SetModel("models/aether/gas_cylinder.mdl")
    self:PhysicsInit(SOLID_VPHYSICS)
    self:SetMoveType(MOVETYPE_VPHYSICS)
    self:SetSolid(SOLID_VPHYSICS)
    self:SetUseType(SIMPLE_USE)
    local phys = self:GetPhysicsObject()
    if IsValid(phys) then phys:Wake() end
    if self:GetGasName() == "" then self:SetGasName(self.InitGas or "chlorine") end
    if self.InitPlain then self:SetPlain(true) end
    self:UpdateSkin()
    self:SetContents(CAPACITY)
end

function ENT:SetValve(open)
    if open == self:GetOpen() then return end
    self:SetOpen(open)
    if open and self:GetContents() > 0 then
        local hose = self.Hose
        if IsValid(hose) then   -- газ идёт по шлангу и выходит из наконечника
            self.SourceId = AetherGas.Solver.AddSource(self:GetGasName(), Vector(4.6, 0, 0), RATE, 0, nil, Vector(120, 0, 0), hose)
        else
            local up = Vector(2.8, 0, 41.5)   -- выход вентиля
            self.SourceId = AetherGas.Solver.AddSource(self:GetGasName(), up, RATE, 0, nil, Vector(60, 0, 10), self)
        end
        self.Hiss = CreateSound(self, "ambient/gas/cannister_loop.wav")
        self.Hiss:PlayEx(0.5, 95)
        self:EmitSound("buttons/lever7.wav")
    else
        if self.SourceId then AetherGas.Solver.StopSource(self.SourceId) end
        self.SourceId = nil
        if self.Hiss then self.Hiss:Stop() end
        self:EmitSound("buttons/lever8.wav")
    end
end

--- Подключить/отключить шланг (вызывает тулган). Открытый вентиль переключается на новый выход.
function ENT:SetHose(nozzle)
    local wasOpen = self:GetOpen()
    if wasOpen then self:SetValve(false) end
    self.Hose = IsValid(nozzle) and nozzle or nil
    if IsValid(nozzle) then
        nozzle.Canister = self
        nozzle:SetCanister(self)
    end
    if wasOpen then self:SetValve(true) end
end

function ENT:Use(activator)
    if IsValid(activator) and activator:IsPlayer() then self:SetValve(not self:GetOpen()) end
end

function ENT:Think()
    if self:GetOpen() then
        local left = self:GetContents() - RATE * 0.1
        self:SetContents(math.max(0, left))
        if left <= 0 then self:SetValve(false) end
    end
    self:NextThink(CurTime() + 0.1)
    return true
end

function ENT:OnRemove()
    if self.Hiss then self.Hiss:Stop() end
    if self.SourceId then AetherGas.Solver.StopSource(self.SourceId) end
end
