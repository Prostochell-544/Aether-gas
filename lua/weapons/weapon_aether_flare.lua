-- lua/weapons/weapon_aether_flare.lua
-- Сигнальные фаеры: ЛКМ — зажечь и бросить, ПКМ — зажечь и положить под ноги, R — сменить цвет.
-- Безвредны (сигнальный дым), но горящий фаер поджигает горючий газ.
AddCSLuaFile()

SWEP.Base         = "weapon_aether_grenade"
SWEP.PrintName    = "Signal Flare (R: colour)"
SWEP.Category     = "Aether Gas"
SWEP.Spawnable    = true
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

function SWEP:HeldSkin()
    local gas = self:CurrentGas()
    for i = 1, #self.GasList do
        if self.GasList[i] == gas then return i - 1 end
    end
    return 0
end

function SWEP:PrimaryAttack()
    self:Throw(700, 140)
end

function SWEP:SecondaryAttack()
    self:Throw(120, 60)
end
