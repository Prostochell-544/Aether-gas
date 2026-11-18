-- lua/aether_gas/client/cl_effects.lua
--[[
    Экранные эффекты и звук для локального игрока. Источник данных — собственная симуляция клиента
    (Solver.Sample у глаз), поэтому сервер ничего для эффектов не шлёт.

    Все уровни сглаживаются к цели (без мерцания на границе вокселя):
      distortion — screen.distortion·c (хлор, марево метана): рефракция effects/water_warp01;
      darken     — накопленная доза CO: доза += c·dt, уходит со скоростью 0.4/с; потемнение и обесцвечивание;
      fog        — screen.fog·c (пар; в противогазе стекло запотевает сильнее), спадает медленно — 0.25/с;
      tint       — лёгкий цветной оттенок газа + виньетка по краям.
    Звук: muffle·c > 0.3 → DSP 14 (глушение); сброс в 0 только если включали сами.
    Противогаз: оверлей, дыхание, шкала фильтра; снять — aether_mask_off (выпадает на землю).
]]

local AetherGas = AetherGas
local Solver    = AetherGas.Solver
local C         = AetherGas.Const
local P         = AetherGas.GasParams

local min, max, Lerp = math.min, math.max, Lerp
local FrameTime = FrameTime

local cvEffects = CreateClientConVar("aether_effects", "1", true, false, "Aether: gas screen effects (0/1).", 0, 1)

local GRAD_L, GRAD_R = Material("vgui/gradient-l"), Material("vgui/gradient-r")
local GRAD_U, GRAD_D = Material("vgui/gradient-u"), Material("vgui/gradient-d")

local state = { distortion = 0, darken = 0, fog = 0, tint = 0, blur = 0, narrow = 0, dose = 0, frost = 0, r = 255, g = 255, b = 255 }
local dspActive = false
local breath

local CM = {
    ["$pp_colour_addr"] = 0, ["$pp_colour_addg"] = 0, ["$pp_colour_addb"] = 0,
    ["$pp_colour_brightness"] = 0, ["$pp_colour_contrast"] = 1, ["$pp_colour_colour"] = 1,
    ["$pp_colour_mulr"] = 0, ["$pp_colour_mulg"] = 0, ["$pp_colour_mulb"] = 0,
}

local function Approach(cur, target, rateUp, rateDown, dt)
    if target > cur then return min(target, cur + rateUp * dt) end
    return max(target, cur - rateDown * dt)
end

hook.Add("Think", "AetherGas.Effects.Update", function()
    local ply = LocalPlayer()
    if not IsValid(ply) then return end
    local dt = FrameTime()
    local alive = ply:Alive()
    -- костюм химзащиты закрывает только кожу: эффекты дыхания и глаз снимает противогаз
    local masked = alive and ply:GetNW2Bool("AetherMask", false)

    local g, c, tEye = 0, 0, 20
    if alive and cvEffects:GetBool() then
        -- как на сервере (sv_network SampleBody): глаза целиком, пояс 70 %, ноги 30 %
        local e = ply:EyePos()
        g, c, tEye = Solver.Sample(e.x, e.y, e.z)
        local m = ply:WorldSpaceCenter()
        local gm, cm = Solver.Sample(m.x, m.y, m.z)
        if gm ~= 0 and cm * 0.7 > c then g, c = gm, cm * 0.7 end
        local f = ply:GetPos()
        local gf, cf = Solver.Sample(f.x, f.y, f.z + 10)
        if gf ~= 0 and cf * 0.3 > c then g, c = gf, cf * 0.3 end
    end
    -- Накопленная доза (сервер, AetherDose): эффекты держатся и после выхода из облака, маска их уже не снимает
    local lingering = false
    local dg, dl = ply:GetNW2Int("AetherDoseGas", 0), ply:GetNW2Float("AetherDose", 0)
    if alive and dg ~= 0 and dl > c then g, c, lingering = dg, min(1, dl), true end
    local def = g ~= 0 and AetherGas.GasById[g]
    local scr = def and def.screen or nil
    local protected = def and not lingering and def.maskProtects and (masked or ply:GetNW2Float("AetherExtMask", 0) >= 0.5)
    -- Холодная струя из баллона (Джоуль — Томсон / испарение сжиженного газа): иней по краям экрана
    local tFrost = (alive and tEye < -5) and min(1, (-5 - tEye) / 50) or 0
    state.frost = Approach(state.frost, tFrost, 2, 0.3, dt)

    local tDist = (scr and scr.distortion or 0) * c * (protected and 0.15 or 1)
    local tFog  = (scr and scr.fog or 0) * c * (masked and 1.4 or 1)
    local tTint = (scr and (scr.tint or scr.distortion) and 1 or 0) * c * (protected and 0.3 or 1)
    -- слёзы (CS, аммиак): картинка плывёт; сужение зрачков (зарин, H2S) — тёмный «туннель»
    local tBlur = (scr and scr.blur or 0) * min(1, c * 2.5) * (protected and 0 or 1)
    local tNarrow = (scr and scr.narrow or 0) * min(1, c * 4) * (protected and 0.4 or 1)

    -- Доза CO копится (гипоксия наступает не сразу), противогаз от CO не спасает
    if def and (scr and scr.darken or 0) > 0 then
        state.dose = min(10, state.dose + scr.darken * c * dt)
    else
        state.dose = max(0, state.dose - 0.4 * dt)
    end

    state.distortion = Approach(state.distortion, tDist, 2, 1, dt)
    state.fog        = Approach(state.fog, min(1, tFog), 1.5, 0.25, dt)
    state.tint       = Approach(state.tint, min(1, tTint), 2, 1, dt)
    state.blur       = Approach(state.blur, min(1, tBlur), 1.5, 0.12, dt)      -- слёзы проходят долго
    state.narrow     = Approach(state.narrow, min(1, tNarrow), 0.8, 0.08, dt)
    state.darken     = min(1, state.dose / 6)
    if def then
        local col = scr and scr.tint or def.color
        state.r = Lerp(dt * 3, state.r, col.r)
        state.g = Lerp(dt * 3, state.g, col.g)
        state.b = Lerp(dt * 3, state.b, col.b)
    end

    -- Глушение звука в плотном облаке
    local muffle = g ~= 0 and P.Muffle[g] * c or 0
    if muffle > 0.3 and not dspActive then
        ply:SetDSP(14, false)
        dspActive = true
    elseif muffle <= 0.2 and dspActive then
        ply:SetDSP(0, false)
        dspActive = false
    end

    -- Дыхание в противогазе
    if masked then
        if not breath then breath = CreateSound(ply, "player/breathe1.wav") end
        if not breath:IsPlaying() then breath:PlayEx(0.35, 100) end
    elseif breath and breath:IsPlaying() then
        breath:Stop()
    end
end)

hook.Add("RenderScreenspaceEffects", "AetherGas.Effects.Screen", function()
    if not cvEffects:GetBool() then return end
    if state.distortion > 0.01 then
        DrawMaterialOverlay("effects/water_warp01", 0.08 * state.distortion)
    end
    if state.blur > 0.01 then
        DrawMotionBlur(0.12, 0.85 * state.blur, 0.02)
        DrawMaterialOverlay("effects/water_warp01", 0.04 * state.blur)
    end
    if state.darken > 0.01 then
        local d = state.darken
        CM["$pp_colour_brightness"] = -0.35 * d
        CM["$pp_colour_contrast"] = 1 - 0.35 * d
        CM["$pp_colour_colour"] = 1 - 0.7 * d
        DrawColorModify(CM)
    end
end)

-- Вид из противогаза: рамка с двумя линзами (2:1, пропорции сохраняются) + запотевание нижней части
-- линз в ритме дыхания (цикл 3.2 с; на бегу чаще и сильнее).
local MAT_MASK, MAT_BREATH = Material("aether/mask_overlay"), Material("aether/mask_breath")
local breathPhase = 0
local function DrawMaskView(w, h)
    local ply = LocalPlayer()
    local run = math.min(ply:GetVelocity():Length2D() / 250, 1)
    breathPhase = breathPhase + FrameTime() * (2 * math.pi / (3.2 - 1.4 * run))
    local exhale = math.max(0, math.sin(breathPhase)) ^ 2
    local ow = math.max(w, h * 2)
    local ox = (w - ow) * 0.5
    local oh = ow * 0.5
    local oy = (h - oh) * 0.5
    surface.SetDrawColor(255, 255, 255, 110 + 120 * exhale * (0.6 + 0.4 * run))
    surface.SetMaterial(MAT_BREATH)
    surface.DrawTexturedRect(ox, oy, ow, oh)
    surface.SetDrawColor(255, 255, 255, 255)
    surface.SetMaterial(MAT_MASK)
    surface.DrawTexturedRect(ox, oy, ow, oh)
    if oy > 0 then
        surface.SetDrawColor(10, 11, 10, 255)
        surface.DrawRect(0, 0, w, oy + 1)
        surface.DrawRect(0, h - oy - 1, w, oy + 1)
    end
end

local function Vignette(w, h, a, r, g, b)
    local s = math.floor(min(w, h) * 0.35)
    surface.SetDrawColor(r, g, b, a)
    surface.SetMaterial(GRAD_L) surface.DrawTexturedRect(0, 0, s, h)
    surface.SetMaterial(GRAD_R) surface.DrawTexturedRect(w - s, 0, s, h)
    surface.SetMaterial(GRAD_U) surface.DrawTexturedRect(0, 0, w, s)
    surface.SetMaterial(GRAD_D) surface.DrawTexturedRect(0, h - s, w, s)
end

hook.Add("HUDPaintBackground", "AetherGas.Effects.Overlay", function()
    if not cvEffects:GetBool() then return end
    local w, h = ScrW(), ScrH()
    if state.tint > 0.01 then
        Vignette(w, h, 200 * state.tint, state.r * 0.5, state.g * 0.5, state.b * 0.5)
        surface.SetDrawColor(state.r, state.g, state.b, 40 * state.tint)
        surface.DrawRect(0, 0, w, h)
    end
    if state.darken > 0.01 then
        Vignette(w, h, 255 * state.darken, 0, 0, 0)
    end
    if state.narrow > 0.01 then   -- миоз: два слоя виньетки, края почти чёрные
        Vignette(w, h, 255 * state.narrow, 0, 0, 0)
        Vignette(w, h, 200 * state.narrow, 0, 0, 0)
    end
    if state.blur > 0.01 then     -- слёзная плёнка
        surface.SetDrawColor(235, 235, 225, 60 * state.blur)
        surface.DrawRect(0, 0, w, h)
    end
    if state.frost > 0.01 then   -- иней: голубовато-белая виньетка
        Vignette(w, h, 220 * state.frost, 225, 240, 255)
        surface.SetDrawColor(220, 235, 255, 35 * state.frost)
        surface.DrawRect(0, 0, w, h)
    end
    if state.fog > 0.01 then
        surface.SetDrawColor(235, 238, 242, 200 * state.fog)
        surface.DrawRect(0, 0, w, h)
    end
end)

-- Шкала фильтра противогаза (маска при себе — шкала видна и снятой, с подсказкой клавиш)
hook.Add("HUDPaint", "AetherGas.Effects.MaskHUD", function()
    local ply = LocalPlayer()
    if not IsValid(ply) then return end
    local suit = ply:GetNW2Bool("AetherSuit", false)
    local contam = ply:GetNW2Float("AetherContam", 0)
    if contam > 0.05 and ply:Alive() then
        local def = AetherGas.GetGas(ply:GetNW2Int("AetherContamGas", 0))
        draw.SimpleTextOutlined(AetherGas.L("hud.contam", def and AetherGas.GasName(def) or "?"),
            "DermaDefaultBold", ScrW() * 0.5, ScrH() - 104, Color(230, 170, 60), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER, 1, color_black)
    end
    if suit then
        draw.SimpleText(AetherGas.L("hud.suit_on"), "DermaDefault", ScrW() * 0.5 - 110, ScrH() - 88,
            Color(236, 200, 40))
    end
    if not ply:GetNW2Bool("AetherMaskOwned", false) then return end
    local worn = ply:GetNW2Bool("AetherMask", false)
    if worn and ply:Alive() and not ply:ShouldDrawLocalPlayer() then DrawMaskView(ScrW(), ScrH()) end
    local frac = math.Clamp(ply:GetNW2Float("AetherFilter", 0) / AetherGas.CVar.MaskFilter:GetFloat(), 0, 1)
    local w, h = 220, 10
    local x, y = ScrW() * 0.5 - w * 0.5, ScrH() - 60
    local spare = ply:GetNW2Int("AetherSpareFilters", 0)
    draw.SimpleText(AetherGas.L(worn and "hud.mask_on" or "hud.mask_off") ..
        (spare > 0 and AetherGas.L("hud.spare", spare) or ""), "DermaDefault", x, y - 14,
        worn and color_white or Color(255, 210, 120))
    surface.SetDrawColor(0, 0, 0, 160)
    surface.DrawRect(x, y, w, h)
    surface.SetDrawColor(frac > 0.25 and 120 or 230, frac > 0.25 and 220 or 60, 90, 220)
    surface.DrawRect(x + 1, y + 1, (w - 2) * frac, h - 2)
end)

concommand.Add("aether_mask_toggle", function()
    net.Start(C.NET_MASK)
    net.WriteUInt(0, 2)
    net.SendToServer()
end, nil, "Aether: put on / take off the gas mask (same as E+R or !mask)")

concommand.Add("aether_mask_drop", function()
    net.Start(C.NET_MASK)
    net.WriteUInt(1, 2)
    net.SendToServer()
end, nil, "Aether: drop the gas mask (keeps the remaining filter)")

---------------------------------------------------------------------------------------------------
-- Лента убийств: своя иконка газа; огонь от детонации (entityflame) — если у сервера нет своей
---------------------------------------------------------------------------------------------------
language.Add("aether_gas", "Toxic Gas")
killicon.Add("aether_gas", "aether/killicon_gas", Color(210, 225, 90, 255))
if not killicon.Exists("entityflame") then
    killicon.Add("entityflame", "aether/killicon_fire", Color(255, 140, 40, 255))
    language.Add("entityflame", "Fire")
end

---------------------------------------------------------------------------------------------------
-- Противогаз на других игроках (и на себе в третьем лице): модель у аттачмента «eyes».
-- Модель (ГП-7): центры линз на высоте 0 и ~1.2 впереди начала координат — оно совпадает с глазами.
---------------------------------------------------------------------------------------------------
local maskModel
hook.Add("PostPlayerDraw", "AetherGas.Effects.MaskModel", function(ply)
    if not ply:GetNW2Bool("AetherMask", false) or not ply:Alive() then return end
    local att = ply:LookupAttachment("eyes")
    if not att or att <= 0 then return end
    local a = ply:GetAttachment(att)
    if not a then return end
    if not IsValid(maskModel) then
        maskModel = ClientsideModel("models/aether/gasmask.mdl", RENDERGROUP_OPAQUE)
        if not IsValid(maskModel) then return end
        maskModel:SetNoDraw(true)
    end
    local ang = a.Ang
    local pos = a.Pos - ang:Forward() * 0.3
    maskModel:SetPos(pos)
    maskModel:SetAngles(ang)
    maskModel:SetModelScale(1)
    maskModel:SetupBones()
    maskModel:DrawModel()
end)

hook.Add("ShutDown", "AetherGas.Effects", function()
    if breath then breath:Stop() end
end)
