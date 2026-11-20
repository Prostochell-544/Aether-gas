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
    AetherGas.OnLanguage("tool.duct", function()
        local L = AetherGas.L
        language.Add("tool.aether_duct.name", L("tool.duct.name"))
        language.Add("tool.aether_duct.desc", L("tool.duct.desc"))
        language.Add("tool.aether_duct.left", L("tool.duct.left"))
        language.Add("tool.aether_duct.left_1", L("tool.duct.left_1"))
        language.Add("tool.aether_duct.right", L("tool.duct.right"))
        language.Add("tool.aether_duct.reload", L("tool.duct.reload"))
        language.Add("tool.aether_duct.rope", L("tool.duct.rope"))
        language.Add("Undone_aether_duct", L("tool.duct.undone"))
    end)
end

local HOSE_WIDTH, DUCT_WIDTH = 1.5, 3.5

local function Hint(ply, key)
    if IsValid(ply) then AetherGas.Notify(ply, 2, key) end
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
            Hint(ply, ent:GetClass() == "aether_canister" and "tool.duct.hint_cyl"
                or "tool.duct.hint_intake_sel")
        elseif not IsValid(ent) or ent:IsWorld() then
            self.First = Place("aether_vent", tr, ply)
            if not IsValid(self.First) then return false end
            self.FirstCreated = true
            Hint(ply, "tool.duct.hint_intake")
        else
            return false
        end
        self:SetStage(1)
        return true
    end

    local first = self.First
    if not IsValid(first) then self:SetStage(0) return false end
    local isHose = first:GetClass() == "aether_canister"
    -- клик по уже стоящей вытяжной решётке — подключить к ней ещё один впуск (несколько впусков → один выпуск)
    local hit = tr.Entity
    local joined = not isHose and IsValid(hit) and hit:GetClass() == "aether_vent" and hit:GetIsOutlet()
    local out = joined and hit or Place(isHose and "aether_hose_nozzle" or "aether_vent", tr, ply, function(e)
        if not isHose then
            e:SetIsOutlet(true)
            if first.GetStyle then e:SetStyle(first:GetStyle()) end   -- выпуск того же вида, что впуск
        end
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
        Hint(ply, "tool.duct.hint_hose")
    else
        first:SetLink(out)
        out:AddInlet(first)
        if first:GetOn() then first:SetActive(false) first:SetActive(true) end
        Hint(ply, "tool.duct.hint_duct")
    end

    undo.Create("aether_duct")
        if not joined then undo.AddEntity(out) end
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
        if ent:GetIsOutlet() then
            -- ПКМ по выпуску: отключить все впуски и убрать выпуск
            local list = ent:GetInlets()
            for i = 1, #list do list[i]:SetActive(false) list[i]:SetLink(NULL) end
            ent:Remove()
            return true
        end
        -- ПКМ по впуску: отсоединить только его; выпуск без впусков убирается
        local outlet = ent:GetLink()
        ent:SetActive(false)
        ent:SetLink(NULL)
        constraint.RemoveConstraints(ent, "Rope")
        if IsValid(outlet) and #outlet:GetInlets() == 0 then outlet:Remove() end
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
    panel:Help(AetherGas.L("tool.duct.help1"))
    panel:Help(AetherGas.L("tool.duct.help2"))
    panel:CheckBox("#tool.aether_duct.rope", "aether_duct_rope")
end
