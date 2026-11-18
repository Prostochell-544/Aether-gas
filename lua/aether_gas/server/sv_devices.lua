-- lua/aether_gas/server/sv_devices.lua
--[[
    Управление устройствами Aether (баллоны, эмиттеры, вентиляторы, воздуходувки, решётки воздуховода):
      • единый API AetherGas.SetDeviceOn / IsDeviceOn / ToggleDevice;
      • Wiremod (если установлен, сверено с lua/wire/server/wirelib.lua: WireLib.CreateInputs/CreateOutputs/
        TriggerOutput; провод вызывает ent:TriggerInput(name, value)):
          входы  On (уровень), Toggle (фронт), Rate (0 — по умолчанию), Detonate (фронт, баллон);
          выходы On, GasAmount (баллон, %), IsPunctured, Leaks;
      • групповое включение: тулган «Aether Valve Group» привязывает устройства к клавише numpad
        (numpad.OnDown → AetherGas.Device.Toggle), как двигатели в Sandbox.
]]

local AetherGas = AetherGas

local DEVICES = {
    aether_canister = { "Open/On", "Toggle", "Rate", "Detonate" },
    aether_emitter  = { "On", "Toggle", "Rate" },
    aether_fan      = { "On", "Toggle" },
    aether_blower   = { "On", "Toggle" },
    aether_vent     = { "On", "Toggle" },
}
AetherGas.DeviceClasses = DEVICES

function AetherGas.IsDevice(ent)
    return IsValid(ent) and DEVICES[ent:GetClass()] ~= nil
end

function AetherGas.IsDeviceOn(ent)
    if ent.GetOpen then return ent:GetOpen() end
    if ent.GetOn then return ent:GetOn() end
    return false
end

function AetherGas.SetDeviceOn(ent, on)
    if not AetherGas.IsDevice(ent) or AetherGas.IsDeviceOn(ent) == on then return end
    if ent.SetValve then ent:SetValve(on)
    elseif ent.SetPower then ent:SetPower(on)
    elseif ent.SetActive then
        -- выпуск воздуховода управляет своим впуском
        if ent:GetClass() == "aether_vent" and ent.GetIsOutlet and ent:GetIsOutlet() then
            if IsValid(ent.Inlet) then ent.Inlet:SetActive(on) end
        else
            ent:SetActive(on)
        end
    end
end

function AetherGas.ToggleDevice(ent)
    if AetherGas.IsDevice(ent) then AetherGas.SetDeviceOn(ent, not AetherGas.IsDeviceOn(ent)) end
end

--- Поменять расход работающего устройства: баллон/эмиттер перезапускают источник с новым rate.
local function SetRate(ent, rate)
    if ent:GetClass() == "aether_canister" then
        ent.Rate = rate > 0 and math.Clamp(rate, 0.5, 30) or nil
    elseif ent.SetRate then
        ent:SetRate(rate > 0 and math.Clamp(rate, 0.5, 30) or 5)
    else
        return
    end
    if AetherGas.IsDeviceOn(ent) then
        AetherGas.SetDeviceOn(ent, false)
        AetherGas.SetDeviceOn(ent, true)
    end
end

---------------------------------------------------------------------------------------------------
-- Wiremod
---------------------------------------------------------------------------------------------------
local Wired = AetherGas.WiredDevices or setmetatable({}, { __mode = "k" })
AetherGas.WiredDevices = Wired

local function WireTriggerInput(self, name, value)
    if name == "On" or name == "Open" then
        AetherGas.SetDeviceOn(self, value ~= 0)
    elseif name == "Toggle" then
        if value ~= 0 then AetherGas.ToggleDevice(self) end
    elseif name == "Rate" then
        SetRate(self, value)
    elseif name == "Detonate" and value ~= 0 and self.Burst then
        local def = AetherGas.GetGas(self:GetGasName())
        self:Burst(def ~= nil and def.flammable)
    end
end

local function AttachWire(ent)
    if not WireLib or not IsValid(ent) or Wired[ent] then return end
    local cls = ent:GetClass()
    local inputs = cls == "aether_canister" and { "Open", "Toggle", "Rate", "Detonate" }
        or (DEVICES[cls][3] and { "On", "Toggle", "Rate" } or { "On", "Toggle" })
    local outputs = cls == "aether_canister" and { "On", "GasAmount", "IsPunctured", "Leaks" } or { "On" }
    ent.Inputs = WireLib.CreateInputs(ent, inputs)
    ent.Outputs = WireLib.CreateOutputs(ent, outputs)
    if not ent.TriggerInput then ent.TriggerInput = WireTriggerInput end
    Wired[ent] = {}
end

hook.Add("OnEntityCreated", "AetherGas.Devices", function(ent)
    timer.Simple(0, function()
        if AetherGas.IsDevice(ent) then AttachWire(ent) end
    end)
end)

-- Выходы: раз в 0.25 с, только при изменении (TriggerOutput сам рассылает по проводам)
local CAPACITY = 120
timer.Create("AetherGas.Devices.WireOutputs", 0.25, 0, function()
    if not WireLib then return end
    for ent, last in pairs(Wired) do
        if IsValid(ent) then
            local on = AetherGas.IsDeviceOn(ent) and 1 or 0
            if last.On ~= on then last.On = on WireLib.TriggerOutput(ent, "On", on) end
            if ent:GetClass() == "aether_canister" then
                local amount = math.floor(ent:GetContents() / CAPACITY * 100 + 0.5)
                local leaks = ent.GetLeaks and ent:GetLeaks() or 0
                if last.Gas ~= amount then last.Gas = amount WireLib.TriggerOutput(ent, "GasAmount", amount) end
                if last.Leaks ~= leaks then
                    last.Leaks = leaks
                    WireLib.TriggerOutput(ent, "Leaks", leaks)
                    WireLib.TriggerOutput(ent, "IsPunctured", leaks > 0 and 1 or 0)
                end
            end
        else
            Wired[ent] = nil
        end
    end
end)

---------------------------------------------------------------------------------------------------
-- Групповое управление клавишей (тулган aether_valve)
---------------------------------------------------------------------------------------------------
numpad.Register("AetherGas.Device.Toggle", function(_, ent)
    if not IsValid(ent) then return false end
    AetherGas.ToggleDevice(ent)
    return true
end)

--- Привязать устройство к клавише игрока. Повторная привязка заменяет прежнюю.
function AetherGas.BindDeviceKey(ply, ent, key)
    if ent.AetherNumpad then numpad.Remove(ent.AetherNumpad) end
    ent.AetherNumpad = numpad.OnDown(ply, key, "AetherGas.Device.Toggle", ent)
    ent.AetherNumpadKey = key
    ent:SetNW2Int("AetherKey", key)
end

function AetherGas.UnbindDeviceKey(ent)
    if ent.AetherNumpad then numpad.Remove(ent.AetherNumpad) end
    ent.AetherNumpad, ent.AetherNumpadKey = nil, nil
    ent:SetNW2Int("AetherKey", 0)
end
