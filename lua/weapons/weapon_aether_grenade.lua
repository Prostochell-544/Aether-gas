-- lua/weapons/weapon_aether_grenade.lua
-- Газовые гранаты: ЛКМ — бросок, ПКМ — навесом под ноги, R — сменить газ.
AddCSLuaFile()

SWEP.PrintName    = "Grenade: ALL GASES (Admin, R)"
SWEP.Author       = "Aether"
SWEP.Category     = "Aether Gas"
SWEP.Spawnable    = true
SWEP.AdminOnly    = true    -- мульти-граната: R переключает газ; обычные — weapon_aether_grenade_<газ>
SWEP.FixedGas     = nil
SWEP.Slot         = 4
SWEP.SlotPos      = 3
SWEP.ViewModel    = "models/weapons/c_grenade.mdl"
SWEP.WorldModel   = "models/aether/gas_grenade.mdl"
SWEP.UseHands     = false
SWEP.HeldMdl      = "models/aether/gas_grenade.mdl"
SWEP.HeldOffset   = Vector(15, 6.5, -8)
SWEP.HeldAngle    = Angle(-12, 290, 0)
SWEP.WorldOffset  = Vector(3, -2, -2)
SWEP.WorldAngle   = Angle(0, 0, 90)
SWEP.DrawAmmo     = false

SWEP.Primary.ClipSize    = -1
SWEP.Primary.DefaultClip = -1
SWEP.Primary.Automatic   = false
SWEP.Primary.Ammo        = "none"
SWEP.Secondary.ClipSize    = -1
SWEP.Secondary.DefaultClip = -1
SWEP.Secondary.Automatic   = false
SWEP.Secondary.Ammo        = "none"

local GASES = AetherGas.BaseGases   -- все газы аддона (порядок = скины модели)

function SWEP:SetupDataTables()
    self:NetworkVar("Int", 0, "GasIndex")
end

function SWEP:Initialize()
    self:SetHoldType("grenade")
    self:SetGasIndex(1)
end

--- Газ гранаты: фиксированный у наследников, выбранный R — у мульти-гранаты.
-- Наследники могут сузить список (SWEP.GasList) и бросать другой класс (SWEP.ThrowClass, например фаер).
function SWEP:GasChoices() return self.GasList or GASES end
function SWEP:CurrentGas()
    local list = self:GasChoices()
    return self.FixedGas or list[self:GetGasIndex()] or list[1]
end
function SWEP:HeldSkin() return AetherGas.GasSkin(self:CurrentGas()) end
-- После броска граната пропадает из руки, через ~0.6 с «достаётся» новая (подъём снизу).
function SWEP:HeldHidden() return (self.ThrownAt or 0) + 0.6 > CurTime() end
function SWEP:HeldExtra(ang)
    local k = math.Clamp(CurTime() - (self.ThrownAt or 0) - 0.6, 0, 0.4) / 0.4
    return -ang:Up() * (1 - k) * 8
end

function SWEP:Throw(speed, upward)
    if CLIENT and IsFirstTimePredicted() then self.ThrownAt = CurTime() end
    self:SendWeaponAnim(ACT_VM_THROW)
    self:GetOwner():SetAnimation(PLAYER_ATTACK1)
    self:SetNextPrimaryFire(CurTime() + 1)
    self:SetNextSecondaryFire(CurTime() + 1)
    timer.Simple(0.6, function()
        if IsValid(self) and IsValid(self:GetOwner()) then self:SendWeaponAnim(ACT_VM_DRAW) end
    end)
    if CLIENT then return end

    local owner = self:GetOwner()
    local g = ents.Create(self.ThrowClass or "aether_grenade")
    if not IsValid(g) then return end
    local aim = owner:GetAimVector()
    g:SetPos(owner:EyePos() + aim * 16 + owner:GetRight() * 6)
    g:SetAngles(aim:Angle())
    g:SetGasName(self:CurrentGas())
    g:SetOwner(owner)
    g:Spawn()
    local phys = g:GetPhysicsObject()
    if IsValid(phys) then
        phys:SetVelocity(aim * speed + Vector(0, 0, upward) + owner:GetVelocity())
        phys:AddAngleVelocity(Vector(600, math.random(-400, 400), 0))
    end
    undo.Create(self.UndoName or "Gas Grenade")
        undo.AddEntity(g)
        undo.SetPlayer(owner)
    undo.Finish()
end

function SWEP:PrimaryAttack()
    self:Throw(900, 120)
end

function SWEP:SecondaryAttack()
    self:Throw(250, 180)
end

function SWEP:Reload()
    if self.FixedGas then return end
    if not IsFirstTimePredicted() or (self.NextCycle or 0) > CurTime() then return end
    self.NextCycle = CurTime() + 0.4
    self:SetGasIndex(self:GetGasIndex() % #self:GasChoices() + 1)
    if CLIENT then surface.PlaySound("weapons/smg1/switch_single.wav") end
end


---------------------------------------------------------------------------------------------------
-- Внешний вид: своя модель «в руке» в пространстве камеры (стоковый c_-viewmodel не рисуется),
-- в мире — у кисти игрока; иконка выбора оружия — сгенерированная materials/entities/<класс>.png.
---------------------------------------------------------------------------------------------------
if CLIENT then
    function SWEP:HeldModel()
        if not IsValid(self.Held) then
            self.Held = ClientsideModel(self.HeldMdl, RENDERGROUP_OPAQUE)
            if IsValid(self.Held) then self.Held:SetNoDraw(true) end
        end
        return self.Held
    end

    function SWEP:PreDrawViewModel()
        local m = self:HeldModel()
        if not IsValid(m) or self:HeldHidden() then return true end
        local pos, ang = EyePos(), EyeAngles()
        local t = CurTime()
        local vel = LocalPlayer():GetVelocity():Length2D()
        local bob = math.sin(t * 9) * math.min(vel / 200, 1) * 0.35
        local off, rot = self.HeldOffset, self.HeldAngle
        local p = pos + ang:Forward() * off.x + ang:Right() * off.y + ang:Up() * (off.z + bob) + self:HeldExtra(ang)
        local a = Angle(ang.p, ang.y, ang.r)
        a:RotateAroundAxis(a:Up(), rot.y)
        a:RotateAroundAxis(a:Right(), rot.p)
        a:RotateAroundAxis(a:Forward(), rot.r)
        m:SetPos(p)
        m:SetAngles(a)
        m:SetSkin(self:HeldSkin())
        m:SetModelScale(self.HeldScale or 1)
        m:SetupBones()
        m:DrawModel()
        if self.HeldPostDraw then self:HeldPostDraw(m) end
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
        self:SetSkin(self:HeldSkin())
        self:DrawModel()
        self:SetRenderOrigin(nil)
        self:SetRenderAngles(nil)
    end

    local ICONS = {}
    function SWEP:DrawWeaponSelection(x, y, w, h, a)
        local cls = self:GetClass()
        ICONS[cls] = ICONS[cls] or Material("entities/" .. cls .. ".png")
        local size = math.min(w, h) - 16
        surface.SetDrawColor(255, 255, 255, a)
        surface.SetMaterial(ICONS[cls])
        surface.DrawTexturedRect(x + (w - size) * 0.5, y + (h - size) * 0.5, size, size)
    end

    function SWEP:OnRemove()
        if IsValid(self.Held) then self.Held:Remove() end
    end
end

function SWEP:DrawHUD()
    local def = AetherGas.GetGas(self:CurrentGas())
    if not def then return end
    draw.SimpleTextOutlined(AetherGas.L("hud.grenade", AetherGas.GasName(def)) ..
        (self.FixedGas and "" or AetherGas.L("hud.grenade_switch")), "DermaLarge", ScrW() * 0.5, ScrH() - 120,
        def.color, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER, 1, color_black)
end
