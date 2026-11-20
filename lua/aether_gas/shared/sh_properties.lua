-- lua/aether_gas/shared/sh_properties.lua
-- Контекстное меню (C → ПКМ по предмету): выбор газа и вкл/выкл для гранат, баллонов, эмиттеров,
-- вентилятора. Работает со штатной системой properties (и с Extended Properties поверх неё).

local GAS_ENTS = { aether_grenade = true, aether_canister = true, aether_emitter = true }
local TOGGLE_ENTS = { aether_canister = true, aether_emitter = true, aether_fan = true, aether_blower = true, aether_vent = true }

local function Allowed(self, ent, ply)
    return gamemode.Call("CanProperty", ply, self.InternalName, ent) ~= false
end

local L = AetherGas.L

properties.Add("aether_gas_type", {
    MenuLabel = L("prop.gas_type"),
    Order = 1600,
    MenuIcon = "icon16/weather_clouds.png",

    Filter = function(self, ent, ply)
        if not IsValid(ent) or not GAS_ENTS[ent:GetClass()] then return false end
        if ent:GetClass() == "aether_grenade" and ent.GetEmitting and ent:GetEmitting() then return false end
        return Allowed(self, ent, ply)
    end,

    MenuOpen = function(self, option, ent)
        local sub = option:AddSubMenu()
        for id = 1, AetherGas.GasCount do
            local def = AetherGas.GasById[id]
            local o = sub:AddOption(AetherGas.GasName(def), function() self:SetGas(ent, def.name) end)
            if ent.GetGasName and ent:GetGasName() == def.name then o:SetChecked(true) end
        end
    end,

    Action = function() end,

    SetGas = function(self, ent, name)
        self:MsgStart()
            net.WriteEntity(ent)
            net.WriteString(name)
        self:MsgEnd()
    end,

    Receive = function(self, _, ply)
        local ent, name = net.ReadEntity(), net.ReadString()
        if not properties.CanBeTargeted(ent, ply) or not self:Filter(ent, ply) or not AetherGas.GetGas(name) then return end
        local wasOn = (ent.GetOpen and ent:GetOpen()) or (ent.GetOn and ent:GetOn())
        if wasOn then
            if ent.SetValve then ent:SetValve(false) elseif ent.SetActive then ent:SetActive(false) end
        end
        ent:SetGasName(name)
        if ent.UpdateSkin then ent:UpdateSkin() else ent:SetSkin(AetherGas.GasSkin(name)) end
        if wasOn then
            if ent.SetValve then ent:SetValve(true) elseif ent.SetActive then ent:SetActive(true) end
        end
    end,
})

-- Вид предмета (баллоны, фаеры, антидоты, вентиляторы, решётки): только виды из ENT.LookStyles
local STYLE_KEYS = { "style.su", "style.nato", "style.modern", "style.classic", "style.plain" }
properties.Add("aether_cylinder_style", {
    MenuLabel = L("prop.style"),
    Order = 1603,
    MenuIcon = "icon16/paintcan.png",

    Filter = function(self, ent, ply)
        return IsValid(ent) and ent.LookStyles ~= nil and ent.GetStyle ~= nil and Allowed(self, ent, ply)
    end,

    MenuOpen = function(self, option, ent)
        local sub = option:AddSubMenu()
        for _, i in ipairs(ent.LookStyles) do
            local o = sub:AddOption(L(STYLE_KEYS[i]), function()
                self:MsgStart()
                    net.WriteEntity(ent)
                    net.WriteUInt(i, 3)
                self:MsgEnd()
            end)
            if ent.GetStyle and ent:GetStyle() == i then o:SetChecked(true) end
        end
    end,

    Action = function() end,

    Receive = function(self, _, ply)
        local ent, st = net.ReadEntity(), net.ReadUInt(3)
        if not properties.CanBeTargeted(ent, ply) or not self:Filter(ent, ply) then return end
        if AetherGas.FitLook(st, ent.LookStyles) ~= st then return end
        ent:SetStyle(st)
        ent:UpdateLook()
    end,
})

properties.Add("aether_toggle", {
    MenuLabel = L("prop.toggle"),
    Order = 1601,
    MenuIcon = "icon16/control_power.png",

    Filter = function(self, ent, ply)
        return IsValid(ent) and TOGGLE_ENTS[ent:GetClass()] == true and Allowed(self, ent, ply)
    end,

    Action = function(self, ent)
        self:MsgStart()
            net.WriteEntity(ent)
        self:MsgEnd()
    end,

    Receive = function(self, _, ply)
        local ent = net.ReadEntity()
        if not properties.CanBeTargeted(ent, ply) or not self:Filter(ent, ply) then return end
        if ent.SetValve then ent:SetValve(not ent:GetOpen())
        elseif ent.SetPower then ent:SetPower(not ent:GetOn())
        elseif ent.SetActive then ent:SetActive(not ent:GetOn()) end
    end,
})
