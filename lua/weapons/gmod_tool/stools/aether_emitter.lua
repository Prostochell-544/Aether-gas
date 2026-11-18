-- lua/weapons/gmod_tool/stools/aether_emitter.lua
-- ЛКМ — поставить эмиттер (включён), ПКМ — разовый выброс в точку, R — убрать весь газ (суперадмин).
TOOL.Category = "Aether Gas"
TOOL.Name     = "#tool.aether_emitter.name"

TOOL.ClientConVar["gas"]      = "smoke"
TOOL.ClientConVar["rate"]     = "5"
TOOL.ClientConVar["duration"] = "6"

if CLIENT then
    AetherGas.OnLanguage("tool.emitter", function()
        local L = AetherGas.L
        language.Add("tool.aether_emitter.name", L("tool.emitter.name"))
        language.Add("tool.aether_emitter.desc", L("tool.emitter.desc"))
        language.Add("tool.aether_emitter.left", L("tool.emitter.left"))
        language.Add("tool.aether_emitter.right", L("tool.emitter.right"))
        language.Add("tool.aether_emitter.reload", L("tool.emitter.reload"))
        language.Add("Undone_aether_emitter", L("tool.emitter.undone"))
        language.Add("Cleanup_aether_emitters", L("tool.emitter.cleanup"))
        language.Add("Cleaned_aether_emitters", L("tool.emitter.cleaned"))
    end)
end
TOOL.Information = { "left", "right", "reload" }

cleanup.Register("aether_emitters")

function TOOL:GasName()
    local name = self:GetClientInfo("gas")
    return AetherGas.GetGas(name) and name or "smoke"
end

function TOOL:LeftClick(tr)
    if CLIENT then return true end
    local ply = self:GetOwner()
    local e = ents.Create("aether_emitter")
    if not IsValid(e) then return false end
    e:SetGasName(self:GasName())
    e:SetRate(math.Clamp(self:GetClientNumber("rate", 5), 0.5, 30))
    e:SetPos(tr.HitPos + tr.HitNormal * 10)
    e:SetAngles(tr.HitNormal:Angle() + Angle(90, 0, 0))
    e:Spawn()
    e:SetActive(true)
    undo.Create("aether_emitter")
        undo.AddEntity(e)
        undo.SetPlayer(ply)
    undo.Finish()
    ply:AddCleanup("aether_emitters", e)
    return true
end

function TOOL:RightClick(tr)
    if CLIENT then return true end
    local pos = tr.HitPos + tr.HitNormal * (AetherGas.Spatial.VoxelSize * 0.5)
    AetherGas.Solver.AddSource(self:GasName(), pos, math.Clamp(self:GetClientNumber("rate", 5), 0.5, 30),
        math.Clamp(self:GetClientNumber("duration", 6), 0.5, 120))
    return true
end

function TOOL:Reload()
    if CLIENT then return true end
    local ply = self:GetOwner()
    if not (ply:IsSuperAdmin() or game.SinglePlayer()) then return false end
    AetherGas.Solver.Clear()
    return true
end

function TOOL.BuildCPanel(panel)
    panel:AddControl("Header", { Description = "#tool.aether_emitter.desc" })
    local L = AetherGas.L
    local combo = panel:ComboBox(L("tool.emitter.gas"), "aether_emitter_gas")
    for id = 1, AetherGas.GasCount do
        local def = AetherGas.GasById[id]
        combo:AddChoice(AetherGas.GasName(def), def.name)
    end
    panel:NumSlider(L("tool.emitter.rate"), "aether_emitter_rate", 0.5, 30, 1)
    panel:NumSlider(L("tool.emitter.duration"), "aether_emitter_duration", 0.5, 120, 1)
end
