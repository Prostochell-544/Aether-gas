-- lua/weapons/gmod_tool/stools/aether_valve.lua
--[[
    Групповой вентиль: привязать баллоны, эмиттеры, вентиляторы и решётки к одной клавише.
      ЛКМ — привязать устройство под прицелом к выбранной клавише;
      ПКМ — отвязать;
      R   — переключить все устройства Aether в радиусе (тот же «рубильник» без привязки).
    Нажатие клавиши переключает все привязанные к ней устройства разом (numpad, как у двигателей).
]]
TOOL.Category = "Aether Gas"
TOOL.Name     = "#tool.aether_valve.name"
TOOL.ClientConVar = { key = "42", radius = "300" }   -- 42 = KEY_PAD_5; выбирается в панели тулгана
TOOL.Information = { { name = "left" }, { name = "right" }, { name = "reload" } }

-- Классы устройств (тот же список, что AetherGas.DeviceClasses в sv_devices; нужен и клиенту для трассера)
local DEVICES = { aether_canister = true, aether_emitter = true, aether_fan = true, aether_blower = true, aether_vent = true }

if CLIENT then
    AetherGas.OnLanguage("tool.valve", function()
        local L = AetherGas.L
        language.Add("tool.aether_valve.name", L("tool.valve.name"))
        language.Add("tool.aether_valve.desc", L("tool.valve.desc"))
        language.Add("tool.aether_valve.left", L("tool.valve.left"))
        language.Add("tool.aether_valve.right", L("tool.valve.right"))
        language.Add("tool.aether_valve.reload", L("tool.valve.reload"))
    end)
end

function TOOL:LeftClick(tr)
    local ent = tr.Entity
    if not IsValid(ent) or not DEVICES[ent:GetClass()] then return false end
    if CLIENT then return true end
    local ply = self:GetOwner()
    if not properties.CanBeTargeted(ent, ply) then return false end
    AetherGas.BindDeviceKey(ply, ent, self:GetClientNumber("key", 42))
    return true
end

function TOOL:RightClick(tr)
    local ent = tr.Entity
    if not IsValid(ent) or not DEVICES[ent:GetClass()] then return false end
    if CLIENT then return true end
    AetherGas.UnbindDeviceKey(ent)
    return true
end

function TOOL:Reload(tr)
    if CLIENT then return true end
    local ply = self:GetOwner()
    local r = math.Clamp(self:GetClientNumber("radius", 300), 50, 2000)
    local n = 0
    for _, ent in ipairs(ents.FindInSphere(tr.HitPos, r)) do
        if AetherGas.IsDevice(ent) and properties.CanBeTargeted(ent, ply) then
            AetherGas.ToggleDevice(ent)
            n = n + 1
        end
    end
    AetherGas.Notify(ply, 2, "tool.valve.toggled", n)
    return n > 0
end

-- Номер клавиши над привязанным устройством, пока в руках этот тулган
if CLIENT then
    function TOOL:DrawHUD()
        for _, ent in ipairs(ents.FindInSphere(LocalPlayer():GetPos(), 1500)) do
            local key = ent:GetNW2Int("AetherKey", 0)
            if key ~= 0 then
                local sp = ent:WorldSpaceCenter():ToScreen()
                if sp.visible then
                    draw.SimpleTextOutlined("[" .. (input.GetKeyName(key) or key) .. "]", "DermaDefaultBold", sp.x, sp.y,
                        Color(120, 220, 255), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER, 1, color_black)
                end
            end
        end
    end
end

function TOOL.BuildCPanel(panel)
    panel:AddControl("Header", { Description = "#tool.aether_valve.desc" })
    local L = AetherGas.L
    panel:AddControl("Numpad", { Label = L("tool.valve.key"), Command = "aether_valve_key" })
    panel:NumSlider(L("tool.valve.radius"), "aether_valve_radius", 50, 2000, 0)
    panel:Help(L("tool.valve.help"))
end
