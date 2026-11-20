-- lua/aether_gas/client/cl_menu.lua
-- Меню Q → Utilities → Aether Gas. Серверные ConVar'ы меняет только суперадмин (net + белый список
-- на сервере, sv_network.lua); клиентские — напрямую.

local AetherGas = AetherGas
local C = AetherGas.Const

-- Вид гранат и фаеров в руках (userinfo: сервер читает GetInfoNum в SWEP:Think). 0 — как настройка сервера.
CreateClientConVar("aether_look_grenade", "0", true, true, "Aether: look of held grenades (0 server, 1 SU, 2 NATO, 4 classic).", 0, 5)
CreateClientConVar("aether_look_flare", "0", true, true, "Aether: look of held flares (0 server, 1 SU, 2 NATO, 4 classic).", 0, 5)

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

local function ServerCombo(panel, label, name, choices)
    local c = panel:ComboBox(label)
    local cv = GetConVar(name)
    local cur = cv and cv:GetInt() or 0
    for i = 1, #choices do c:AddChoice(choices[i][1], choices[i][2], choices[i][2] == cur) end
    c.OnSelect = function(_, _, _, v) SendServerCVar(name, v) end
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
    panel:CheckBox(L("menu.ultra"), "aether_ultra")
    panel:ControlHelp(L("menu.ultra_help"))
    panel:NumSlider(L("menu.ultra_fade"), "aether_ultra_fade", 1, 200, 0)
    panel:NumSlider(L("menu.ultra_motion"), "aether_ultra_motion", 0, 3, 2)
    panel:Help(L("menu.held_look"))
    for _, it in ipairs({ { "menu.look_grenade", "aether_look_grenade" }, { "menu.look_flare", "aether_look_flare" } }) do
        local c = panel:ComboBox(L(it[1]), it[2])
        c:AddChoice(L("style.server"), 0)
        c:AddChoice(L("style.su"), 1)
        c:AddChoice(L("style.nato"), 2)
        c:AddChoice(L("style.classic"), 4)
    end
    panel:ControlHelp(L("menu.held_look_help"))
    panel:Button(L("menu.mask_toggle"), "aether_mask_toggle")
    panel:Button(L("menu.mask_drop"), "aether_mask_drop")
    panel:Button(L("menu.suit_drop"), "aether_suit_drop")
    panel:Help(L("menu.mask_fit"))
    panel:NumSlider(L("menu.mask_fit_scale"), "aether_mask_fit_scale", 0.5, 2, 2)
    panel:NumSlider(L("menu.mask_fit_forward"), "aether_mask_fit_forward", -4, 4, 2)
    panel:NumSlider(L("menu.mask_fit_up"), "aether_mask_fit_up", -4, 4, 2)
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
    ServerCombo(panel, L("menu.cyl_style"), "aether_cylinder_style", {
        { L("style.random"), 0 }, { L("style.su"), 1 }, { L("style.nato"), 2 }, { L("style.modern"), 3 },
        { L("style.classic"), 4 }, { L("style.plain"), 5 } })
    panel:ControlHelp(L("menu.cyl_style_help"))
    panel:Button(L("menu.clear"), "aether_clear")
end

hook.Add("PopulateToolMenu", "AetherGas.Menu", function()
    spawnmenu.AddToolMenuOption("Utilities", "Aether Gas", "aether_gas_settings", AetherGas.L("menu.settings"), "", "", BuildPanel)
end)
