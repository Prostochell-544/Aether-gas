-- lua/aether_gas/client/cl_gas_editor.lua
--[[
    Меню газомёта (ПКМ с weapon_aether_gasgun): слева — что и как распылять (ConVar'ы aether_gun_*),
    справа — редактор пользовательских газов (слоты custom_1..4). Поля редактора строятся по
    AetherGas.CustomGasFields (sh_custom.lua) — тот же белый список, что проверяет сервер.
    «Apply» шлёт слот на сервер; сервер проверяет права и рассылает газ всем.
]]

local AetherGas = AetherGas
local L = AetherGas.L
local frame

local function GasChoices(combo, selected)
    combo:Clear()
    for id = 1, AetherGas.GasCount do
        local def = AetherGas.GasById[id]
        local label = (def.custom and "* " or "") .. AetherGas.GasName(def)
        combo:AddChoice(label, def.name, def.name == selected)
    end
end

local function BuildGunSide(parent)
    local p = vgui.Create("DScrollPanel", parent)
    p:Dock(LEFT)
    p:SetWide(330)
    p:DockMargin(0, 0, 8, 0)

    local function Label(text)
        local l = p:Add("DLabel")
        l:Dock(TOP)
        l:DockMargin(4, 8, 4, 2)
        l:SetText(text)
        l:SetFont("DermaDefaultBold")
        l:SetDark(true)
    end

    Label(L("editor.gas"))
    local combo = p:Add("DComboBox")
    combo:Dock(TOP)
    combo:DockMargin(4, 0, 4, 0)
    GasChoices(combo, GetConVar("aether_gun_gas"):GetString())
    combo.OnSelect = function(_, _, _, name) RunConsoleCommand("aether_gun_gas", name) end
    p.GasCombo = combo

    Label(L("editor.mode"))
    local mode = p:Add("DComboBox")
    mode:Dock(TOP)
    mode:DockMargin(4, 0, 4, 0)
    mode:AddChoice(L("editor.mode_aim"), 1, GetConVar("aether_gun_mode"):GetInt() ~= 2)
    mode:AddChoice(L("editor.mode_jet"), 2, GetConVar("aether_gun_mode"):GetInt() == 2)
    mode.OnSelect = function(_, _, _, v) RunConsoleCommand("aether_gun_mode", tostring(v)) end

    local function Slider(text, cvar, lo, hi, dec)
        local s = p:Add("DNumSlider")
        s:Dock(TOP)
        s:DockMargin(4, 4, 4, 0)
        s:SetText(text)
        s:SetMinMax(lo, hi)
        s:SetDecimals(dec)
        s:SetConVar(cvar)
        s:SetDark(true)
    end
    Label(L("editor.sprayer"))
    Slider(L("editor.rate"), "aether_gun_rate", 0.5, 30, 1)
    Slider(L("editor.distance"), "aether_gun_distance", 32, 1500, 0)
    Slider(L("editor.radius"), "aether_gun_spread", 0, 3, 0)
    Slider(L("editor.jet_speed"), "aether_gun_velocity", 0, 800, 0)
    Slider(L("editor.temp"), "aether_gun_temp", -200, 800, 0)

    local help = p:Add("DLabel")
    help:Dock(TOP)
    help:DockMargin(4, 10, 4, 0)
    help:SetWrap(true)
    help:SetAutoStretchVertical(true)
    help:SetDark(true)
    help:SetText(L("editor.help"))
    return p
end

local function BuildEditor(parent, gunSide)
    local p = vgui.Create("DScrollPanel", parent)
    p:Dock(FILL)
    local controls, current = {}, AetherGas.CustomSlots[1]

    local top = p:Add("DPanel")
    top:Dock(TOP)
    top:SetTall(26)
    top:SetPaintBackground(false)
    local slot = vgui.Create("DComboBox", top)
    slot:Dock(LEFT)
    slot:SetWide(170)
    local base = vgui.Create("DComboBox", top)
    base:Dock(FILL)
    base:DockMargin(6, 0, 0, 0)
    GasChoices(base)   -- Clear() внутри сбрасывает текст, поэтому подсказка — после заполнения
    base:SetValue(L("editor.start_from"))

    local function Load(flat)
        for key, ctl in pairs(controls) do
            local v = flat[key]
            if ctl.Kind == "num" then ctl:SetValue(tonumber(v) or 0)
            elseif ctl.Kind == "bool" then ctl:SetChecked(v == true)
            elseif ctl.Kind == "string" then ctl:SetValue(v or "")
            elseif ctl.Kind == "color" then ctl:SetColor(Color(v and v.r or 200, v and v.g or 200, v and v.b or 200))
            elseif ctl.Kind == "enum" then ctl:ChooseOptionID(1) for i = 1, #AetherGas.DamageKinds do
                    if AetherGas.DamageKinds[i][1] == v then ctl:ChooseOptionID(i) end
                end
            end
        end
    end

    local function Collect()
        local flat = {}
        for key, ctl in pairs(controls) do
            if ctl.Kind == "num" then flat[key] = ctl:GetValue()
            elseif ctl.Kind == "bool" then flat[key] = ctl:GetChecked()
            elseif ctl.Kind == "string" then flat[key] = ctl:GetValue()
            elseif ctl.Kind == "color" then local c = ctl:GetColor() flat[key] = { r = c.r, g = c.g, b = c.b }
            elseif ctl.Kind == "enum" then local _, v = ctl:GetSelected() flat[key] = v or "toxic" end
        end
        return flat
    end

    for i = 1, #AetherGas.CustomSlots do
        local name = AetherGas.CustomSlots[i]
        slot:AddChoice(L("editor.edit_slot", name), name, i == 1)
    end
    slot.OnSelect = function(_, _, _, name)
        current = name
        Load(AetherGas.CustomGasToFlat(AetherGas.GetGas(name)))
    end
    base.OnSelect = function(_, _, _, name)
        local flat = AetherGas.CustomGasToFlat(AetherGas.GetGas(name))
        flat.printName = L("editor.custom_prefix", AetherGas.GasName(AetherGas.GetGas(name)))
        Load(flat)
    end

    for i = 1, #AetherGas.CustomGasFields do
        local f = AetherGas.CustomGasFields[i]
        local key, kind, lo, hi, label, dec = f[1], f[2], f[3], f[4], f[5], f[6]
        if AetherGas.HasL("field." .. key) then label = L("field." .. key) end
        local ctl
        if kind == "num" then
            ctl = p:Add("DNumSlider")
            ctl:SetText(label)
            ctl:SetMinMax(lo, hi)
            ctl:SetDecimals(dec or 2)
            ctl:SetDark(true)
        elseif kind == "bool" then
            ctl = p:Add("DCheckBoxLabel")
            ctl:SetText(label)
            ctl:SetDark(true)
        elseif kind == "string" then
            ctl = p:Add("DTextEntry")
            ctl:SetPlaceholderText(label)
        elseif kind == "color" then
            ctl = p:Add("DColorMixer")
            ctl:SetPalette(false)
            ctl:SetAlphaBar(false)
            ctl:SetWangs(true)
            ctl:SetTall(110)
        elseif kind == "enum" then
            ctl = p:Add("DComboBox")
            for k = 1, #AetherGas.DamageKinds do
                local kindName = AetherGas.DamageKinds[k][1]
                ctl:AddChoice(L("editor.damage_type", L("dmg." .. kindName)), kindName)
            end
        end
        ctl:Dock(TOP)
        ctl:DockMargin(4, 4, 4, 0)
        ctl.Kind = kind
        controls[key] = ctl
    end

    local buttons = p:Add("DPanel")
    buttons:Dock(TOP)
    buttons:DockMargin(4, 10, 4, 4)
    buttons:SetTall(28)
    buttons:SetPaintBackground(false)
    local apply = vgui.Create("DButton", buttons)
    apply:Dock(LEFT)
    apply:SetWide(150)
    apply:SetText(L("editor.apply"))
    apply.DoClick = function()
        AetherGas.SubmitCustomGas(current, Collect())
        surface.PlaySound("buttons/button14.wav")
    end
    local use = vgui.Create("DButton", buttons)
    use:Dock(FILL)
    use:DockMargin(6, 0, 0, 0)
    use:SetText(L("editor.apply_spray"))
    use.DoClick = function()
        AetherGas.SubmitCustomGas(current, Collect())
        RunConsoleCommand("aether_gun_gas", current)
        surface.PlaySound("buttons/button14.wav")
        if IsValid(gunSide) then GasChoices(gunSide.GasCombo, current) end
    end

    Load(AetherGas.CustomGasToFlat(AetherGas.GetGas(current)))
    return p
end

--- Открыть меню газомёта (повторный вызов закрывает).
function AetherGas.OpenGasEditor()
    if IsValid(frame) then frame:Close() return end
    frame = vgui.Create("DFrame")
    frame:SetTitle(L("editor.title"))
    frame:SetSize(math.min(ScrW() - 40, 820), math.min(ScrH() - 40, 640))
    frame:Center()
    frame:MakePopup()
    frame.Gun = BuildGunSide(frame)
    BuildEditor(frame, frame.Gun)
end

-- Сменился язык: меню перестраивается при следующем открытии
AetherGas.OnLanguage("editor", function() if IsValid(frame) then frame:Close() end end)

-- Сервер прислал новые параметры пользовательского газа: обновить имена в списке (редактор не трогаем)
hook.Add("AetherGas.CustomGasChanged", "AetherGas.Editor", function()
    if IsValid(frame) and IsValid(frame.Gun) then
        GasChoices(frame.Gun.GasCombo, GetConVar("aether_gun_gas"):GetString())
    end
end)
