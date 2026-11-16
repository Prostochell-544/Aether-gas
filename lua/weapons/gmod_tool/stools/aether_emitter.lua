-- lua/weapons/gmod_tool/stools/aether_emitter.lua
-- ЛКМ — поставить эмиттер (включён), ПКМ — разовый выброс в точку, R — убрать весь газ (суперадмин).
TOOL.Category = "Aether Gas"
TOOL.Name     = "#tool.aether_emitter.name"

TOOL.ClientConVar["gas"]      = "smoke"
TOOL.ClientConVar["rate"]     = "5"
TOOL.ClientConVar["duration"] = "6"

if CLIENT then
    language.Add("tool.aether_emitter.name", "Gas Emitter")
    language.Add("tool.aether_emitter.desc", "Place gas emitters or release puffs of gas")
    language.Add("tool.aether_emitter.left", "Place emitter (E on it toggles)")
    language.Add("tool.aether_emitter.right", "One-shot release at the aimed point")
    language.Add("tool.aether_emitter.reload", "Remove all gas (superadmin)")
    language.Add("Undone_aether_emitter", "Undone Gas Emitter")
    language.Add("Cleanup_aether_emitters", "Gas Emitters")
    language.Add("Cleaned_aether_emitters", "Cleaned up all Gas Emitters")
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
    local combo = panel:ComboBox("Gas", "aether_emitter_gas")
    for id = 1, AetherGas.GasCount do
        local def = AetherGas.GasById[id]
        combo:AddChoice(def.printName, def.name)
    end
    panel:NumSlider("Release rate", "aether_emitter_rate", 0.5, 30, 1)
    panel:NumSlider("One-shot duration (s)", "aether_emitter_duration", 0.5, 120, 1)
end
