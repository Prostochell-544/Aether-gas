-- lua/weapons/gmod_tool/stools/aether_duct.lua
--[[
    Воздуховоды и шланги.
      Баллон:  ЛКМ по баллону → ЛКМ по точке — наконечник шланга; газ из открытого вентиля идёт туда.
      Воздух:  ЛКМ по стене/полу (или по впускной решётке) → ЛКМ по второй точке — выпуск, соединённый трубой;
               «E» на впуске (или выпуске) включает перекачку газа.
      ПКМ — отсоединить шланг/трубу у сущности под прицелом. R — отменить выбор первой точки.
]]
TOOL.Category = "Aether Gas"
TOOL.Name     = "#tool.aether_duct.name"
TOOL.ClientConVar = { rope = "1" }
TOOL.Information = {
    { name = "left", stage = 0 }, { name = "left_1", stage = 1 }, { name = "right" }, { name = "reload", stage = 1 },
}

if CLIENT then
    language.Add("tool.aether_duct.name", "Gas Duct / Hose")
    language.Add("tool.aether_duct.desc", "Connect a canister to a hose nozzle, or an intake vent to an exhaust vent")
    language.Add("tool.aether_duct.left", "Select a gas canister, or place / select an intake vent")
    language.Add("tool.aether_duct.left_1", "Place the hose nozzle / exhaust vent")
    language.Add("tool.aether_duct.right", "Disconnect the hose or duct of the aimed object")
    language.Add("tool.aether_duct.reload", "Cancel")
    language.Add("tool.aether_duct.rope", "Draw the hose / duct pipe")
    language.Add("Undone_aether_duct", "Undone Gas Duct")
end

local HOSE_WIDTH, DUCT_WIDTH = 1.5, 3.5

local function Hint(ply, text)
    if IsValid(ply) then ply:PrintMessage(HUD_PRINTCENTER, text) end
end
local CANISTER_VALVE = Vector(2.8, 0, 41.5)

local function Place(class, tr, ply, extra)
    local e = ents.Create(class)
    if not IsValid(e) then return nil end
    local ang = tr.HitNormal:Angle()            -- +X модели — от поверхности
    e:SetAngles(ang)
    if extra then extra(e) end
    e:Spawn()
    -- отодвинуть, чтобы не утонуть в поверхности
    local mins = e:OBBMins()
    e:SetPos(tr.HitPos - tr.HitNormal * mins.x + tr.HitNormal * 1)
    if tr.Entity and tr.Entity:IsWorld() then
        local phys = e:GetPhysicsObject()
        if IsValid(phys) then phys:EnableMotion(false) end
    end
    if IsValid(ply) then ply:AddCleanup("aether_emitters", e) end
    return e
end

function TOOL:LeftClick(tr)
    if CLIENT then return true end
    local ply = self:GetOwner()

    if self:GetStage() == 0 then
        local ent = tr.Entity
        if IsValid(ent) and (ent:GetClass() == "aether_canister" or (ent:GetClass() == "aether_vent" and not ent:GetIsOutlet())) then
            self.First = ent
            Hint(ply, ent:GetClass() == "aether_canister" and "Cylinder selected: click where the hose nozzle goes"
                or "Intake selected: click where the exhaust vent goes")
        elseif not IsValid(ent) or ent:IsWorld() then
            self.First = Place("aether_vent", tr, ply)
            if not IsValid(self.First) then return false end
            self.FirstCreated = true
            Hint(ply, "Intake vent placed: click where the exhaust vent goes")
        else
            return false
        end
        self:SetStage(1)
        return true
    end

    local first = self.First
    if not IsValid(first) then self:SetStage(0) return false end
    local isHose = first:GetClass() == "aether_canister"
    local out = Place(isHose and "aether_hose_nozzle" or "aether_vent", tr, ply, function(e)
        if not isHose then e:SetIsOutlet(true) end
    end)
    if not IsValid(out) then return false end

    local p1 = isHose and CANISTER_VALVE or Vector(-10.5, 0, 0)
    local p2 = Vector(-3, 0, 0)
    if not isHose then p2 = Vector(-10.5, 0, 0) end
    local len = first:LocalToWorld(p1):Distance(out:LocalToWorld(p2))
    -- Трос держит выход на длине шланга; видимость — опция тулгана (ширина 0 — невидимый трос)
    local width = self:GetClientNumber("rope", 1) ~= 0 and (isHose and HOSE_WIDTH or DUCT_WIDTH) or 0
    local _, rope = constraint.Rope(first, out, 0, 0, p1, p2, len * 1.15, 0, 0, width, "cable/cable2", false)

    if isHose then
        first:SetHose(out)
        Hint(ply, "Hose connected: press E on the cylinder or the nozzle to open the valve")
    else
        first:SetLink(out)
        out.Inlet = first
        if first:GetOn() then first:SetActive(false) first:SetActive(true) end
        Hint(ply, "Duct connected: press E on a vent to start pumping")
    end

    undo.Create("aether_duct")
        undo.AddEntity(out)
        if IsValid(rope) then undo.AddEntity(rope) end
        if self.FirstCreated then undo.AddEntity(first) end
        undo.SetPlayer(ply)
    undo.Finish()

    self.First, self.FirstCreated = nil, nil
    self:SetStage(0)
    return true
end

function TOOL:RightClick(tr)
    if CLIENT then return true end
    local ent = tr.Entity
    if not IsValid(ent) then return false end
    local cls = ent:GetClass()
    if cls == "aether_canister" and IsValid(ent.Hose) then
        local nozzle = ent.Hose
        ent:SetHose(nil)
        nozzle:Remove()
        return true
    elseif cls == "aether_hose_nozzle" then
        ent:Remove()
        return true
    elseif cls == "aether_vent" then
        local inlet = ent:GetIsOutlet() and ent.Inlet or ent
        local outlet = ent:GetIsOutlet() and ent or (IsValid(ent:GetLink()) and ent:GetLink())
        if IsValid(inlet) then inlet:SetActive(false) inlet:SetLink(NULL) end
        if IsValid(outlet) then outlet:Remove() end
        return true
    end
    return false
end

function TOOL:Reload()
    if CLIENT then return true end
    if self:GetStage() == 1 then
        if self.FirstCreated and IsValid(self.First) then self.First:Remove() end
        self.First, self.FirstCreated = nil, nil
        self:SetStage(0)
        return true
    end
    return false
end

function TOOL.BuildCPanel(panel)
    panel:AddControl("Header", { Description = "#tool.aether_duct.desc" })
    panel:Help("Canister → hose: LMB on the canister, then LMB where the nozzle should be. Open the valve (E) — gas flows out of the nozzle.")
    panel:Help("Duct: LMB on a wall/floor places the intake vent, second LMB places the exhaust vent. Press E on a vent to start pumping: the intake sucks gas in front of its grille and the exhaust blows the same gas out.")
    panel:CheckBox("#tool.aether_duct.rope", "aether_duct_rope")
end
