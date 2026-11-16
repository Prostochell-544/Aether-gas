-- lua/weapons/weapon_aether_gasgun.lua
--[[
    Газомёт: ЛКМ (удерживать) — распылять выбранный газ, ПКМ — меню (газ, напор, дальность, режим и
    редактор пользовательских газов), R — убрать газ под прицелом.

    Режимы: 1 — облачко в точке прицела (до aether_gun_distance), 2 — струя из сопла вдоль взгляда.
    Каждые PERIOD с сервер делает Solver.PuffAt (одно событие ~35 байт), а не создаёт источники.
    Настройки — клиентские userinfo-ConVar'ы aether_gun_*; сервер читает их через GetInfo и ограничивает.
    Права: AetherGas.CanUseGasGun(ply, gasName) (хук AetherGas.CanUseGasGun, ConVar aether_gasgun_toxic_admin).
]]
AddCSLuaFile()

SWEP.PrintName    = "Gas Sprayer"
SWEP.Author       = "Aether"
SWEP.Category     = "Aether Gas"
SWEP.Instructions = "LMB: spray gas. RMB: settings and custom gas editor. R: remove gas at aim."
SWEP.Spawnable    = true
SWEP.AdminOnly    = false
SWEP.Slot         = 4
SWEP.SlotPos      = 1
SWEP.ViewModel    = "models/weapons/c_pistol.mdl"
SWEP.WorldModel   = "models/aether/gas_sprayer.mdl"
SWEP.UseHands     = false
SWEP.DrawAmmo     = false
SWEP.HeldMdl      = "models/aether/gas_sprayer.mdl"
SWEP.HeldOffset   = Vector(15, 6.5, -6.5)
SWEP.HeldAngle    = Angle(-2, -3, 0)
SWEP.WorldOffset  = Vector(3.5, -1.2, -1.5)
SWEP.WorldAngle   = Angle(0, 0, 180)

SWEP.Primary.ClipSize    = -1
SWEP.Primary.DefaultClip = -1
SWEP.Primary.Automatic   = true
SWEP.Primary.Ammo        = "none"
SWEP.Secondary.ClipSize    = -1
SWEP.Secondary.DefaultClip = -1
SWEP.Secondary.Automatic   = false
SWEP.Secondary.Ammo        = "none"

local PERIOD = 0.1


if CLIENT then
    -- userinfo: сервер читает через ply:GetInfo*
    CreateClientConVar("aether_gun_gas", "smoke", true, true, "Aether gas sprayer: gas name")
    CreateClientConVar("aether_gun_rate", "6", true, true, "Aether gas sprayer: concentration per second", 0.5, 30)
    CreateClientConVar("aether_gun_distance", "300", true, true, "Aether gas sprayer: spray distance", 32, 1500)
    CreateClientConVar("aether_gun_spread", "1", true, true, "Aether gas sprayer: puff radius in voxels", 0, 3)
    CreateClientConVar("aether_gun_velocity", "150", true, true, "Aether gas sprayer: jet speed", 0, 800)
    CreateClientConVar("aether_gun_temp", "-200", true, true, "Aether gas sprayer: temperature (-200 = gas default)", -200, 800)
    CreateClientConVar("aether_gun_mode", "1", true, true, "Aether gas sprayer: 1 = at aim point, 2 = jet from nozzle", 1, 2)
end

--- Можно ли игроку распылять газ. Хук AetherGas.CanUseGasGun(ply, gasName) → false запрещает.
function AetherGas.CanUseGasGun(ply, gasName)
    if hook.Run("AetherGas.CanUseGasGun", ply, gasName) == false then return false end
    local def = AetherGas.GetGas(gasName)
    if not def then return false end
    if AetherGas.CVar.GunToxicAdmin:GetBool() and (def.damage > 0 or def.flammable) then
        return game.SinglePlayer() or ply:IsAdmin()
    end
    return true
end

function SWEP:Initialize()
    self:SetHoldType("pistol")
end

--- Точка выброса и направление: режим 1 — у поверхности под прицелом, режим 2 — перед соплом.
function SWEP:SprayPoint(ply)
    local eye, aim = ply:GetShootPos(), ply:GetAimVector()
    local s = AetherGas.Spatial.VoxelSize
    if ply:GetInfoNum("aether_gun_mode", 1) == 2 then
        local tr = util.TraceLine({ start = eye, endpos = eye + aim * 56, filter = ply })
        return tr.HitPos - aim * 8, aim
    end
    local dist = math.Clamp(ply:GetInfoNum("aether_gun_distance", 300), 32, 1500)
    local tr = util.TraceLine({ start = eye, endpos = eye + aim * dist, filter = ply })
    local pos = tr.HitPos - aim * (s * 0.6)
    if tr.Hit then pos = pos + tr.HitNormal * (s * 0.4) end
    return pos, aim
end

function SWEP:PrimaryAttack()
    self:SetNextPrimaryFire(CurTime() + PERIOD)
    if CLIENT then return end
    local ply = self:GetOwner()
    if not IsValid(ply) or not ply:IsPlayer() then return end
    local def = AetherGas.GetGas(ply:GetInfo("aether_gun_gas"))
    if not def then return end
    if not AetherGas.CanUseGasGun(ply, def.name) then
        if (self.DenyMsg or 0) < CurTime() then
            ply:ChatPrint("[Aether] Only admins can spray toxic or flammable gases on this server.")
            self.DenyMsg = CurTime() + 3
        end
        return
    end
    local rate = math.Clamp(ply:GetInfoNum("aether_gun_rate", 6), 0.5, 30)
    local spread = math.Clamp(math.floor(ply:GetInfoNum("aether_gun_spread", 1)), 0, 3)
    local speed = math.Clamp(ply:GetInfoNum("aether_gun_velocity", 150), 0, 800)
    local temp = ply:GetInfoNum("aether_gun_temp", -200)
    temp = temp < -199 and def.emitTemp or math.Clamp(temp, -150, 800)
    local pos, aim = self:SprayPoint(ply)
    AetherGas.Solver.PuffAt(def.name, pos, rate * PERIOD, temp, aim * speed, spread)

    if not self.Hiss then
        self.Hiss = CreateSound(self, "ambient/gas/cannister_loop.wav")
    end
    if not self.Hiss:IsPlaying() then self.Hiss:PlayEx(0.45, 125) end
    self.HissUntil = CurTime() + PERIOD * 2.5
end

function SWEP:Reload()
    if CLIENT or (self.NextVacuum or 0) > CurTime() then return end
    self.NextVacuum = CurTime() + 0.25
    local ply = self:GetOwner()
    if not IsValid(ply) or not ply:IsPlayer() then return end
    local tr = util.TraceLine({ start = ply:GetShootPos(), endpos = ply:GetShootPos() + ply:GetAimVector() * 600, filter = ply })
    AetherGas.Solver.PuffAt(nil, tr.HitPos + tr.HitNormal * 8, 0, nil, nil, 3)
    self:EmitSound("ambient/machines/thumper_dust.wav", 60, 160)
end

-- Меню открывается на клиенте: в одиночной игре атаки идут только на сервере → CallOnClient.
function SWEP:SecondaryAttack()
    self:SetNextSecondaryFire(CurTime() + 0.3)
    if SERVER then
        if game.SinglePlayer() then self:CallOnClient("OpenMenu") end
        return
    end
    if IsFirstTimePredicted() then self:OpenMenu() end
end

function SWEP:OpenMenu()
    if CLIENT and AetherGas.OpenGasEditor then AetherGas.OpenGasEditor() end
end

function SWEP:Think()
    if SERVER and self.Hiss and self.Hiss:IsPlaying() and CurTime() > (self.HissUntil or 0) then
        self.Hiss:FadeOut(0.2)
    end
end

function SWEP:Holster()
    if self.Hiss then self.Hiss:Stop() end
    return true
end

function SWEP:OnRemove()
    if self.Hiss then self.Hiss:Stop() end
    if CLIENT and IsValid(self.Held) then self.Held:Remove() end
end

if SERVER then return end

---------------------------------------------------------------------------------------------------
-- Вид: модель в пространстве камеры (+X модели = сопло вперёд), бак окрашен в цвет выбранного газа
-- ($color2 материала бака на время отрисовки), на сопле — короткий «выхлоп» при стрельбе.
---------------------------------------------------------------------------------------------------
local TANK = Material("models/aether/sprayer_tank")
local COLOR2 = Vector(1, 1, 1)

local function GunGas()
    return AetherGas.GetGas(GetConVar("aether_gun_gas"):GetString()) or AetherGas.GetGas("smoke")
end

local function DrawTinted(m)
    local def = GunGas()
    COLOR2:SetUnpacked(def.color.r / 255, def.color.g / 255, def.color.b / 255)
    TANK:SetVector("$color2", COLOR2)
    m:DrawModel()
    COLOR2:SetUnpacked(1, 1, 1)
    TANK:SetVector("$color2", COLOR2)
end

function SWEP:HeldModel()
    if not IsValid(self.Held) then
        self.Held = ClientsideModel(self.HeldMdl, RENDERGROUP_OPAQUE)
        if IsValid(self.Held) then self.Held:SetNoDraw(true) end
    end
    return self.Held
end

function SWEP:PreDrawViewModel()
    local m = self:HeldModel()
    if not IsValid(m) then return true end
    local pos, ang = EyePos(), EyeAngles()
    local vel = LocalPlayer():GetVelocity():Length2D()
    local bob = math.sin(CurTime() * 9) * math.min(vel / 200, 1) * 0.35
    local firing = LocalPlayer():KeyDown(IN_ATTACK)
    local kick = firing and math.sin(CurTime() * 60) * 0.08 or 0
    local off, rot = self.HeldOffset, self.HeldAngle
    local p = pos + ang:Forward() * (off.x + kick) + ang:Right() * off.y + ang:Up() * (off.z + bob)
    local a = Angle(ang.p, ang.y, ang.r)
    a:RotateAroundAxis(a:Up(), rot.y)
    a:RotateAroundAxis(a:Right(), rot.p)
    a:RotateAroundAxis(a:Forward(), rot.r)
    m:SetPos(p)
    m:SetAngles(a)
    m:SetupBones()
    DrawTinted(m)
    return true
end

function SWEP:DrawWorldModel()
    local owner = self:GetOwner()
    if IsValid(owner) then
        local bone = owner:LookupBone("ValveBiped.Bip01_R_Hand")
        local mtx = bone and owner:GetBoneMatrix(bone)
        if mtx then
            local pos, ang = mtx:GetTranslation(), mtx:GetAngles()
            local o = self.WorldOffset
            pos = pos + ang:Forward() * o.x + ang:Right() * o.y + ang:Up() * o.z
            ang:RotateAroundAxis(ang:Right(), self.WorldAngle.p)
            ang:RotateAroundAxis(ang:Up(), self.WorldAngle.y)
            ang:RotateAroundAxis(ang:Forward(), self.WorldAngle.r)
            self:SetRenderOrigin(pos)
            self:SetRenderAngles(ang)
        end
    end
    DrawTinted(self)
    self:SetRenderOrigin(nil)
    self:SetRenderAngles(nil)
end

local ICON = Material("entities/weapon_aether_gasgun.png")
function SWEP:DrawWeaponSelection(x, y, w, h, a)
    local size = math.min(w, h) - 16
    surface.SetDrawColor(255, 255, 255, a)
    surface.SetMaterial(ICON)
    surface.DrawTexturedRect(x + (w - size) * 0.5, y + (h - size) * 0.5, size, size)
end

function SWEP:DrawHUD()
    local def = GunGas()
    local mode = GetConVar("aether_gun_mode"):GetInt() == 2 and "jet" or "at aim"
    local txt = string.format("%s   %.1f/s   %s   [RMB] settings  [R] vacuum", def.printName,
        GetConVar("aether_gun_rate"):GetFloat(), mode)
    draw.SimpleTextOutlined(txt, "DermaLarge", ScrW() * 0.5, ScrH() - 120, def.color, TEXT_ALIGN_CENTER,
        TEXT_ALIGN_CENTER, 1, color_black)
    if GetConVar("aether_gun_mode"):GetInt() == 1 then   -- куда ляжет облако
        local ply = LocalPlayer()
        local dist = GetConVar("aether_gun_distance"):GetFloat()
        local tr = util.TraceLine({ start = ply:GetShootPos(), endpos = ply:GetShootPos() + ply:GetAimVector() * dist, filter = ply })
        local sp = tr.HitPos:ToScreen()
        surface.SetDrawColor(def.color.r, def.color.g, def.color.b, 200)
        surface.DrawOutlinedRect(sp.x - 8, sp.y - 8, 16, 16)
    end
end


