-- lua/aether_gas/client/cl_menu.lua
-- Меню Q → Utilities → Aether Gas. Серверные ConVar'ы меняет только суперадмин (net + белый список
-- на сервере, sv_network.lua); клиентские — напрямую.

local AetherGas = AetherGas
local C = AetherGas.Const

local function SendServerCVar(name, value)
    -- Ползунок шлёт значение при каждом шаге: отправляем последнее через 0.3 с тишины.
    timer.Create("AetherGas.Menu." .. name, 0.3, 1, function()
        net.Start(C.NET_ADMIN_CVAR)
        net.WriteString(name)
        net.WriteString(tostring(value))
        net.SendToServer()
    end)
end

local function ServerSlider(panel, label, name, lo, hi, decimals, help)
    local s = panel:NumSlider(label, nil, lo, hi, decimals)
    local cv = GetConVar(name)
    s:SetValue(cv and cv:GetFloat() or lo)
    s.OnValueChanged = function(_, v) SendServerCVar(name, decimals == 0 and math.Round(v) or v) end
    if help then panel:ControlHelp(help) end
    return s
end

local function ServerCheck(panel, label, name)
    local c = panel:CheckBox(label)
    local cv = GetConVar(name)
    c:SetValue(cv and cv:GetBool() or false)
    c.OnChange = function(_, v) SendServerCVar(name, v and 1 or 0) end
    return c
end

local function BuildPanel(panel)
    local L = AetherGas.L
    panel:ClearControls()
    panel:Help(L("menu.title", AetherGas.Version))

    -- язык интерфейса: auto — по языку игры; смена пересобирает меню Q и подписи тулганов (sh_lang.lua)
    local lang = panel:ComboBox(L("menu.language"), "aether_language")
    lang:AddChoice(L("lang.auto"), "auto")
    for _, code in ipairs(AetherGas.Languages) do lang:AddChoice(AetherGas.Lang[code]["lang.name"], code) end

    panel:Help(L("menu.client"))
    panel:CheckBox(L("menu.draw"), "aether_draw")
    panel:CheckBox(L("menu.effects"), "aether_effects")
    panel:NumSlider(L("menu.draw_distance"), "aether_draw_distance", 500, 30000, 0)
    panel:NumSlider(L("menu.mesh_budget"), "aether_mesh_budget", 0.25, 8, 2)
    panel:Button(L("menu.mask_toggle"), "aether_mask_toggle")
    panel:Button(L("menu.mask_drop"), "aether_mask_drop")
    panel:Button(L("menu.suit_drop"), "aether_suit_drop")
    panel:ControlHelp(L("menu.protection"))

    panel:Help(L("menu.analyzer"))
    panel:CheckBox(L("menu.an_screen"), "aether_analyzer_screen")
    panel:CheckBox(L("menu.an_hud"), "aether_analyzer_hud")
    panel:CheckBox(L("menu.an_beep"), "aether_analyzer_beep")
    panel:CheckBox(L("menu.an_marker"), "aether_analyzer_marker")

    panel:Help(L("menu.sprayer"))
    local open = panel:Button(L("menu.sprayer_open"))
    open.DoClick = function() if AetherGas.OpenGasEditor then AetherGas.OpenGasEditor() end end

    local isAdmin = LocalPlayer():IsSuperAdmin() or game.SinglePlayer()
    panel:Help(isAdmin and L("menu.server_admin") or L("menu.server_noadmin"))
    if not isAdmin then return end

    ServerCheck(panel, L("menu.enabled"), "aether_enabled")
    ServerSlider(panel, L("menu.voxel"), "aether_voxel_size", 32, 128, 0, L("menu.voxel_help"))
    ServerSlider(panel, L("menu.max_chunks"), "aether_max_chunks", 16, 4096, 0)
    ServerSlider(panel, L("menu.tick_budget"), "aether_tick_budget", 0.25, 4, 2)
    ServerSlider(panel, L("menu.probe_budget"), "aether_probe_budget", 4, 256, 0)
    ServerCheck(panel, L("menu.grates"), "aether_grates_block")
    ServerSlider(panel, L("menu.damage_scale"), "aether_damage_scale", 0, 10, 2)
    ServerCheck(panel, L("menu.npc_blind"), "aether_npc_blind")
    ServerSlider(panel, L("menu.mask_filter"), "aether_mask_filter", 10, 3600, 0)
    ServerSlider(panel, L("menu.wind_speed"), "aether_wind_speed", 0, 600, 0)
    ServerSlider(panel, L("menu.wind_yaw"), "aether_wind_yaw", 0, 360, 0)
    ServerCheck(panel, L("menu.stormfox"), "aether_wind_stormfox")
    ServerSlider(panel, L("menu.sync"), "aether_sync_interval", 0.1, 10, 1)
    ServerSlider(panel, L("menu.tunnel"), "aether_tunnel_strength", 0, 1, 2, L("menu.tunnel_help"))
    ServerSlider(panel, L("menu.fire_smoke"), "aether_fire_smoke", 0, 5, 2, L("menu.fire_smoke_help"))
    ServerCheck(panel, L("menu.fire_vfire"), "aether_fire_vfire")
    ServerCheck(panel, L("menu.vfire_wind"), "aether_vfire_wind")
    ServerCheck(panel, L("menu.custom_everyone"), "aether_custom_gas_everyone")
    ServerCheck(panel, L("menu.toxic_admin"), "aether_gasgun_toxic_admin")
    panel:Button(L("menu.clear"), "aether_clear")
end

hook.Add("PopulateToolMenu", "AetherGas.Menu", function()
    spawnmenu.AddToolMenuOption("Utilities", "Aether Gas", "aether_gas_settings", AetherGas.L("menu.settings"), "", "", BuildPanel)
end)
