-- lua/weapons/weapon_aether_analyzer.lua
--[[
    Газоанализатор: показывает газ, концентрацию, температуру и опасность в точке замера.
    ЛКМ — переключить точку: у лица ↔ под прицелом (до 512 юнитов). Писк учащается с концентрацией.
    ПКМ — какие интерфейсы показывать: экран прибора + панель на HUD → только прибор → только HUD.
    Отдельно (Q → Utilities → Aether Gas): aether_analyzer_screen / _hud / _beep / _marker.
    Данные берутся из клиентской симуляции (Solver.Sample) — без сетевых запросов.
]]
AddCSLuaFile()

SWEP.PrintName    = "Gas Analyzer"
SWEP.Author       = "Aether"
SWEP.Category     = "Aether Gas"
SWEP.Spawnable    = true
SWEP.Slot         = 5
SWEP.SlotPos      = 3
SWEP.ViewModel    = "models/weapons/c_medkit.mdl"
SWEP.WorldModel   = "models/aether/gas_analyzer.mdl"
SWEP.UseHands     = false
SWEP.HeldMdl      = "models/aether/gas_analyzer.mdl"
SWEP.HeldOffset   = Vector(17, 5.5, -7)
SWEP.HeldAngle    = Angle(0, 0, 0)     -- не используется: экран (+X модели) всегда смотрит прямо в глаза
SWEP.HeldScale    = 0.85
SWEP.WorldOffset  = Vector(3, -1.5, -1)
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

if CLIENT then
    CreateClientConVar("aether_analyzer_screen", "1", true, false, "Aether analyzer: live screen on the device (0/1)", 0, 1)
    CreateClientConVar("aether_analyzer_hud", "1", true, false, "Aether analyzer: HUD panel (0/1)", 0, 1)
    CreateClientConVar("aether_analyzer_beep", "1", true, false, "Aether analyzer: beeping (0/1)", 0, 1)
    CreateClientConVar("aether_analyzer_marker", "1", true, false, "Aether analyzer: remote probe marker (0/1)", 0, 1)
end

-- Точка замера — сетевая переменная: в одиночной игре атаки выполняются только на сервере
function SWEP:SetupDataTables()
    self:NetworkVar("Bool", 0, "Remote")
end

function SWEP:Initialize()
    self:SetHoldType("slam")
end

function SWEP:PrimaryAttack()
    self:SetNextPrimaryFire(CurTime() + 0.3)
    self:SetRemote(not self:GetRemote())
    if IsFirstTimePredicted() then self:EmitSound("buttons/button15.wav", 50) end
end

function SWEP:SecondaryAttack()
    self:SetNextSecondaryFire(CurTime() + 0.3)
    if SERVER then
        if game.SinglePlayer() then self:CallOnClient("CycleDisplay") end
        return
    end
    if IsFirstTimePredicted() then self:CycleDisplay() end
end

--- Экран + HUD → только экран → только HUD → экран + HUD
function SWEP:CycleDisplay()
    if not CLIENT then return end
    local scr, hud = GetConVar("aether_analyzer_screen"):GetBool(), GetConVar("aether_analyzer_hud"):GetBool()
    if scr and hud then scr, hud = true, false
    elseif scr then scr, hud = false, true
    else scr, hud = true, true end
    RunConsoleCommand("aether_analyzer_screen", scr and "1" or "0")
    RunConsoleCommand("aether_analyzer_hud", hud and "1" or "0")
    surface.PlaySound("buttons/button16.wav")
    notification.AddLegacy("Analyzer: " .. (scr and hud and "device screen + HUD" or scr and "device screen only" or "HUD only"),
        NOTIFY_GENERIC, 2)
end

function SWEP:HeldSkin() return 0 end
function SWEP:HeldHidden() return false end
function SWEP:HeldExtra() return vector_origin end

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
        -- экран прибора (+X модели) развёрнут точно на глаз, верх модели — по «вверх» взгляда
        local toEye = pos - p
        toEye:Normalize()
        local a = toEye:AngleEx(ang:Up())
        a:RotateAroundAxis(a:Up(), rot.y)
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

    local ICON = Material("entities/weapon_aether_analyzer.png")
    function SWEP:DrawWeaponSelection(x, y, w, h, a)
        local size = math.min(w, h) - 16
        surface.SetDrawColor(255, 255, 255, a)
        surface.SetMaterial(ICON)
        surface.DrawTexturedRect(x + (w - size) * 0.5, y + (h - size) * 0.5, size, size)
    end

    function SWEP:OnRemove()
        if IsValid(self.Held) then self.Held:Remove() end
    end
end

if SERVER then return end

local P = AetherGas.GasParams

-- Живой экран прибора: плоскость экрана — грань +X модели, x = +Y модели, y вниз = −Z модели.
-- Угол левого верхнего угла экрана (1.13, −1.6, 6.4); размер 3.2 × 2.7 юнита → 320 × 270 пикселей при 0.01.
local SCREEN_TL = Vector(1.13, -1.6, 6.4)
local cvScreen, cvHud, cvBeep, cvMarker = GetConVar("aether_analyzer_screen"), GetConVar("aether_analyzer_hud"),
    GetConVar("aether_analyzer_beep"), GetConVar("aether_analyzer_marker")

function SWEP:HeldPostDraw(m)
    if not cvScreen:GetBool() then return end
    local _, g, c, t = self:Sample()
    local def = AetherGas.GasById[g]
    local status, scol = self.StatusOf(g, c, def)
    local s = m:GetModelScale()
    local pos = m:LocalToWorld(SCREEN_TL * s)
    local ang = (-m:GetRight()):AngleEx(m:GetForward())
    cam.Start3D2D(pos, ang, 0.01 * s)
        surface.SetDrawColor(6, 18, 10, 255)
        surface.DrawRect(0, 0, 320, 270)
        draw.SimpleText(def and def.printName or "NO GAS", "DermaLarge", 14, 12, def and def.color or Color(90, 255, 120))
        draw.SimpleText(string.format("%5.1f %%", c * 100), "DermaLarge", 14, 70, Color(90, 255, 120))
        draw.SimpleText(string.format("%4.0f C", t), "DermaLarge", 190, 70, Color(90, 255, 120))
        surface.SetDrawColor(30, 60, 36, 255)
        surface.DrawRect(14, 128, 292, 16)
        surface.SetDrawColor(scol.r, scol.g, scol.b, 255)
        surface.DrawRect(14, 128, 292 * c, 16)
        draw.SimpleText(status, "DermaLarge", 160, 200, scol, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
        draw.SimpleText(self:GetRemote() and "REMOTE" or "LOCAL", "DermaDefaultBold", 306, 250, Color(90, 255, 120), TEXT_ALIGN_RIGHT, TEXT_ALIGN_BOTTOM)
    cam.End3D2D()
end

local function Status(g, c, def)  -- также SWEP.StatusOf для экрана
    if g == 0 then return "CLEAR", Color(120, 230, 120) end
    if def.flammable and c >= def.flameMin and c <= def.flameMax then return "EXPLOSIVE MIX", Color(255, 80, 40) end
    if P.Damage[g] > 0 and c >= P.DamageThreshold[g] then return "TOXIC", Color(255, 200, 40) end
    if def.blocksVision and c >= def.visionThreshold then return "NO VISIBILITY", Color(200, 200, 220) end
    return "TRACE", Color(170, 220, 255)
end

SWEP.StatusOf = Status

function SWEP:Sample()
    local ply = self:GetOwner()
    local pos
    if self:GetRemote() then
        local tr = util.TraceLine({ start = ply:EyePos(), endpos = ply:EyePos() + ply:GetAimVector() * 512, filter = ply })
        pos = tr.HitPos - ply:GetAimVector() * 8
    else
        pos = ply:EyePos()
    end
    return pos, AetherGas.Solver.Sample(pos.x, pos.y, pos.z)
end

function SWEP:Think()
    local _, g, c = self:Sample()
    if cvBeep:GetBool() and g ~= 0 and c > 0.02 and CurTime() >= (self.NextBeep or 0) then
        surface.PlaySound("buttons/blip1.wav")
        self.NextBeep = CurTime() + math.Clamp(1.2 - c * 1.1, 0.08, 1.2)
    end
end

function SWEP:DrawHUD()
    local pos, g, c, t = self:Sample()
    local def = AetherGas.GasById[g]
    local status, scol = Status(g, c, def)
    if self:GetRemote() and cvMarker:GetBool() then
        local sp = pos:ToScreen()
        surface.SetDrawColor(scol.r, scol.g, scol.b, 200)
        surface.DrawOutlinedRect(sp.x - 6, sp.y - 6, 12, 12)
    end
    if not cvHud:GetBool() then return end
    local x, y, w, h = ScrW() - 320, ScrH() * 0.5 - 80, 290, 150
    draw.RoundedBox(6, x, y, w, h, Color(10, 14, 12, 220))
    draw.SimpleText("AETHER GAS ANALYZER", "DermaDefaultBold", x + 12, y + 10, Color(150, 255, 150))
    draw.SimpleText(self:GetRemote() and "probe: remote [LMB]   display [RMB]" or "probe: breathing zone [LMB]   display [RMB]", "DermaDefault", x + 12, y + 28, Color(140, 160, 140))
    draw.SimpleText("Gas:   " .. (def and def.printName or "—"), "DermaLarge", x + 12, y + 48, def and def.color or color_white)
    draw.SimpleText(string.format("Conc:  %5.1f %%    Temp: %4.0f C", c * 100, t), "DermaDefaultBold", x + 12, y + 86, color_white)
    surface.SetDrawColor(40, 50, 45, 255)
    surface.DrawRect(x + 12, y + 106, w - 24, 8)
    surface.SetDrawColor(scol.r, scol.g, scol.b, 255)
    surface.DrawRect(x + 12, y + 106, (w - 24) * c, 8)
    draw.SimpleText(status, "DermaLarge", x + w - 12, y + 118, scol, TEXT_ALIGN_RIGHT)
end
