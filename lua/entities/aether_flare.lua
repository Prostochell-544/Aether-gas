-- lua/entities/aether_flare.lua
--[[
    Ручной сигнальный фаер. Горит BURN секунд: цветное пламя (свет + свечение + искры) и столб
    сигнального дыма своего цвета (источник газа на кончике, тёплый — поднимается). Горящий фаер
    поджигает горючий газ вокруг кончика (метан, водород, сероводород) — с ним в газовое облако не лезут.
    В воде гаснет. Газ — keyvalue «gas» (signal_red … signal_orange) или SetGasName до Spawn.
]]
AddCSLuaFile()

ENT.Type      = "anim"
ENT.Base      = "base_anim"
ENT.PrintName = "Signal Flare"
ENT.Author    = "Aether"
ENT.Category  = "Aether Gas"
ENT.Spawnable = false   -- в спавн-меню — пресеты по цветам
ENT.RenderGroup = RENDERGROUP_BOTH

local BURN      = 45      -- секунд горения
local RATE      = 1.0     -- концентрация/с: тонкий шлейф (≈1/5 сигнальной гранаты 9×25), комнату не заливает
local TIP       = Vector(0, 0, 10.2)   -- горящий конец в координатах модели
local EMIT_TEMP = 90      -- дым горячий у кончика: поднимается столбом, остыв — стелется
local COLORS    = { "signal_red", "signal_green", "signal_yellow", "signal_violet", "signal_orange" }
ENT.FlareGases  = COLORS

--- Скин модели фаера по газу (порядок = FLARE_ORDER в tools/make_models.py).
function ENT.FlareSkin(name)
    for i = 1, #COLORS do
        if COLORS[i] == name then return i - 1 end
    end
    return 0
end

for i = 1, #COLORS do
    local name = COLORS[i]
    local def = AetherGas.GetGas(name)
    if def then
        list.Set("SpawnableEntities", "aether_flare_" .. name, {
            PrintName = "Flare: " .. string.gsub(def.printName, "Signal Smoke ", ""),
            ClassName = "aether_flare",
            Category  = "Aether Gas",
            KeyValues = { gas = name },
            IconOverride = "entities/aether_flare_" .. name .. ".png",
        })
    end
end

function ENT:SetupDataTables()
    self:NetworkVar("String", 0, "GasName")
    self:NetworkVar("Float", 0, "BurnEnd")
end

function ENT:KeyValue(key, value)
    if string.lower(key) == "gas" and AetherGas.GetGas(value) then self.InitGas = value end
end

function ENT:IsBurning()
    return self:GetBurnEnd() > CurTime()
end

if CLIENT then
    local GLOW = Material("aether/flare_glow")
    local TipPos = Vector(0, 0, 0)

    function ENT:Draw()
        self:DrawModel()
    end

    function ENT:DrawTranslucent()
        self:DrawModel()
        if not self:IsBurning() then return end
        local def = AetherGas.GetGas(self:GetGasName())
        if not def then return end
        local c = def.color
        TipPos:Set(self:LocalToWorld(TIP))
        local t = CurTime()
        local flick = 0.85 + 0.15 * math.sin(t * 37 + self:EntIndex()) * math.sin(t * 23)
        render.SetMaterial(GLOW)
        render.DrawSprite(TipPos, 34 * flick, 34 * flick, Color(c.r, c.g, c.b, 255))
        render.DrawSprite(TipPos, 10, 10, Color(255, 245, 230, 255))   -- белое ядро пламени
    end

    function ENT:Think()
        if not self:IsBurning() then return end
        local def = AetherGas.GetGas(self:GetGasName())
        if not def then return end
        local tip = self:LocalToWorld(TIP)
        local dl = DynamicLight(self:EntIndex())
        if dl then
            local flick = 0.85 + 0.15 * math.random()
            dl.pos = tip
            dl.r, dl.g, dl.b = def.color.r, def.color.g, def.color.b
            dl.brightness = 3 * flick
            dl.decay = 1000
            dl.size = 260 * flick
            dl.dietime = CurTime() + 0.1
        end
        if (self.NextSpark or 0) < CurTime() then
            self.NextSpark = CurTime() + 0.08
            local ed = EffectData()
            ed:SetOrigin(tip)
            ed:SetNormal(self:GetUp())
            ed:SetMagnitude(1)
            ed:SetScale(0.3)
            ed:SetRadius(2)
            util.Effect("MetalSpark", ed)
        end
        self:SetNextClientThink(CurTime())
        return true
    end
    return
end

function ENT:Initialize()
    self:SetModel("models/aether/signal_flare.mdl")
    self:PhysicsInit(SOLID_VPHYSICS)
    self:SetMoveType(MOVETYPE_VPHYSICS)
    self:SetSolid(SOLID_VPHYSICS)
    self:SetCollisionGroup(COLLISION_GROUP_WEAPON)
    self:SetUseType(SIMPLE_USE)
    local phys = self:GetPhysicsObject()
    if IsValid(phys) then phys:Wake() end
    if self:GetGasName() == "" then self:SetGasName(self.InitGas or "signal_red") end
    self:SetSkin(self.FlareSkin(self:GetGasName()))
    self:Light()
end

--- Зажечь (при спавне). Повторный вызов на прогоревшем фаере ничего не делает.
function ENT:Light()
    if self.Lit then return end
    self.Lit = true
    self:SetBurnEnd(CurTime() + BURN)
    self.SourceId = AetherGas.Solver.AddSource(self:GetGasName(), TIP, RATE, BURN, EMIT_TEMP, Vector(0, 0, 30), self)
    self.Hiss = CreateSound(self, "ambient/fire/fire_small_loop1.wav")
    self.Hiss:PlayEx(0.5, 145)
    self:EmitSound("ambient/fire/ignite.wav", 65, 120)
end

function ENT:BurnOut()
    self:SetBurnEnd(0)
    if self.SourceId then AetherGas.Solver.StopSource(self.SourceId) end
    self.SourceId = nil
    if self.Hiss then self.Hiss:FadeOut(0.5) end
    SafeRemoveEntityDelayed(self, 30)
end

-- «E» — подобрать горящий фаер в руки нельзя, но можно поднять физганом; Use — просто толкнуть.
function ENT:Use(activator)
    local phys = self:GetPhysicsObject()
    if IsValid(phys) and IsValid(activator) then phys:ApplyForceCenter(activator:GetAimVector() * 150) end
end

function ENT:Think()
    if self.Lit and self:GetBurnEnd() > 0 then
        if CurTime() >= self:GetBurnEnd() or self:WaterLevel() >= 2 then
            self:BurnOut()
        else
            -- Открытое пламя на кончике поджигает горючую смесь (вклад в цепную детонацию солвера)
            local tip = self:LocalToWorld(TIP)
            local key = AetherGas.Spatial.WorldToVoxel(tip.x, tip.y, tip.z)
            local idx = key and AetherGas.Solver.KeyIndex(key, false)
            if idx then
                local g = AetherGas.Spatial.Gas[idx]
                local c = AetherGas.Spatial.Conc[idx]
                local P = AetherGas.GasParams
                if g ~= 0 and c >= P.FlameMin[g] and c <= P.FlameMax[g] then AetherGas.Solver.BroadcastIgnite(key) end
            end
        end
    end
    self:NextThink(CurTime() + 0.25)
    return true
end

function ENT:OnRemove()
    if self.Hiss then self.Hiss:Stop() end
    if self.SourceId then AetherGas.Solver.StopSource(self.SourceId) end
end
