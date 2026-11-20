-- lua/weapons/weapon_aether_flare.lua
-- Сигнальный фаер: ЛКМ — зажечь и бросить, ПКМ — зажечь и положить под ноги.
-- В меню — пять фаеров по цветам (weapon_aether_flare_<цвет>, FixedGas); этот класс — их база и старый фаер
-- с выбором цвета на R (скрыт из меню, оставлен для сохранений и дупов).
-- Вид (СССР / НАТО / классика) — настройка игрока aether_look_flare (меню Q), иначе aether_cylinder_style;
-- брошенный фаер того же вида, что в руке.
-- Безвредны (сигнальный дым), но горящий фаер поджигает горючий газ.
AddCSLuaFile()

SWEP.Base         = "weapon_aether_grenade"
SWEP.PrintName    = "Signal Flare (R: colour)"
SWEP.Category     = "Aether Gas"
SWEP.Spawnable    = false
SWEP.AdminOnly    = false
SWEP.FixedGas     = nil
SWEP.SlotPos      = 2
SWEP.WorldModel   = "models/aether/signal_flare.mdl"
SWEP.HeldMdl      = "models/aether/signal_flare.mdl"
SWEP.HeldOffset   = Vector(15, 6.5, -9)
SWEP.HeldAngle    = Angle(-20, 290, 0)
SWEP.ThrowClass   = "aether_flare"
SWEP.UndoName     = "Signal Flare"
SWEP.GasList      = { "signal_red", "signal_green", "signal_yellow", "signal_violet", "signal_orange" }
SWEP.LookStyles   = { 1, 2, 4 }
SWEP.LookConVar   = "aether_look_flare"
local LOOK_GROUP  = { [1] = 0, [2] = 1, [4] = 2 }   -- группы скинов модели фаера (make_models: СССР, НАТО, классика)

function SWEP:SetupDataTables()
    self:NetworkVar("Int", 0, "GasIndex")
    self:NetworkVar("Int", 1, "Style")
end

function SWEP:Initialize()
    self:SetHoldType("grenade")
    self:SetGasIndex(1)
    if SERVER then
        self.DefaultStyle = AetherGas.PickItemLook(self.LookStyles)
        self:SetStyle(self.DefaultStyle)
    end
end

function SWEP:HeldSkin()
    local gas = self:CurrentGas()
    local group = (LOOK_GROUP[self:GetStyle()] or 0) * #self.GasList
    for i = 1, #self.GasList do
        if self.GasList[i] == gas then return group + i - 1 end
    end
    return group
end

function SWEP:PrimaryAttack()
    self:Throw(700, 140)
end

function SWEP:SecondaryAttack()
    self:Throw(120, 60)
end
