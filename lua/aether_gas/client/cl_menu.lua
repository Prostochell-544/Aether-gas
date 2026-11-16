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
    panel:ClearControls()
    panel:Help("Aether — Volumetric Smoke & Gas Dynamics v" .. AetherGas.Version)

    panel:Help("Client")
    panel:CheckBox("Draw gas clouds", "aether_draw")
    panel:CheckBox("Screen effects (cough, distortion, fog)", "aether_effects")
    panel:NumSlider("Draw distance", "aether_draw_distance", 500, 30000, 0)
    panel:NumSlider("Mesh rebuild budget (ms/frame)", "aether_mesh_budget", 0.25, 8, 2)
    panel:Button("Gas mask: put on / take off  (E+R, !mask)", "aether_mask_toggle")
    panel:Button("Gas mask: drop", "aether_mask_drop")

    panel:Help("Gas analyzer (RMB with the analyzer cycles screen / HUD)")
    panel:CheckBox("Live screen on the device", "aether_analyzer_screen")
    panel:CheckBox("HUD panel", "aether_analyzer_hud")
    panel:CheckBox("Beeping", "aether_analyzer_beep")
    panel:CheckBox("Remote probe marker", "aether_analyzer_marker")

    panel:Help("Gas sprayer (RMB with the sprayer opens the same menu)")
    local open = panel:Button("Open sprayer settings and custom gas editor")
    open.DoClick = function() if AetherGas.OpenGasEditor then AetherGas.OpenGasEditor() end end

    local isAdmin = LocalPlayer():IsSuperAdmin() or game.SinglePlayer()
    panel:Help(isAdmin and "Server (superadmin)" or "Server settings: superadmin only")
    if not isAdmin then return end

    ServerCheck(panel, "Simulation enabled", "aether_enabled")
    ServerSlider(panel, "Voxel size (detail)", "aether_voxel_size", 32, 128, 0,
        "Smaller = finer spreading but more CPU: cell count grows as 1/size^3 " ..
        "(32 ≈ 2x cells of 40, 64 ≈ 4x fewer). Changing it resets all gas.")
    ServerSlider(panel, "Max active chunks", "aether_max_chunks", 16, 4096, 0)
    ServerSlider(panel, "Solver budget (ms/tick)", "aether_tick_budget", 0.25, 4, 2)
    ServerSlider(panel, "Collision probe budget (traces/tick)", "aether_probe_budget", 4, 256, 0)
    ServerCheck(panel, "Grates block gas", "aether_grates_block")
    ServerSlider(panel, "Damage scale", "aether_damage_scale", 0, 10, 2)
    ServerCheck(panel, "Smoke blinds NPCs / NextBots", "aether_npc_blind")
    ServerSlider(panel, "Gas mask filter (s)", "aether_mask_filter", 10, 3600, 0)
    ServerSlider(panel, "Wind speed", "aether_wind_speed", 0, 600, 0)
    ServerSlider(panel, "Wind direction (yaw)", "aether_wind_yaw", 0, 360, 0)
    ServerCheck(panel, "Use StormFox 2 wind", "aether_wind_stormfox")
    ServerSlider(panel, "Client sync interval (s)", "aether_sync_interval", 0.1, 10, 1)
    ServerSlider(panel, "Bullets clear smoke (tunnel strength)", "aether_tunnel_strength", 0, 1, 2,
        "How much gas a bullet knocks out along its path. 0 = bullets do not cut smoke.")
    ServerSlider(panel, "Smoke from fire", "aether_fire_smoke", 0, 5, 2,
        "vFire, env_fire (Fire Tool) and burning props emit fire smoke. 0 = fire does not smoke.")
    ServerCheck(panel, "Gas explosions spread vFire", "aether_fire_vfire")
    ServerCheck(panel, "vFire flames lean with Aether wind", "aether_vfire_wind")
    ServerCheck(panel, "Everyone may edit custom gases", "aether_custom_gas_everyone")
    ServerCheck(panel, "Only admins spray toxic / flammable gases", "aether_gasgun_toxic_admin")
    panel:Button("Remove all gas", "aether_clear")
end

hook.Add("PopulateToolMenu", "AetherGas.Menu", function()
    spawnmenu.AddToolMenuOption("Utilities", "Aether Gas", "aether_gas_settings", "Settings", "", "", BuildPanel)
end)
