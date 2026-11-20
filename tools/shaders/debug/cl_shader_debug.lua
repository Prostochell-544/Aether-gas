-- lua/aether_gas/client/cl_shader.lua
--[[
    Режим «Ультра» (в разработке): свои пиксельные шейдеры через материал screenspace_general.
    Шейдеры собираются tools/build_shaders.py (HLSL → fxc → VCS) в shaders/fxc/aether_*.vcs.

    Диагностика пути, до переноса облаков на шейдер:
      aether_shader_test <режим> [масштаб] [20b|30]
        режим 0 — глубина кадра на весь экран: слева канал R, справа канал A (×масштаб);
        режим 1 — тестовый квад перед игроком: слева цвета вершин (красный, зелёный, синий, белый по углам),
                  справа градиент UV;
        режим 2 — весь экран пурпурный: наш шейдер вообще выполняется;
        режим 3 — весь экран штатным материалом: работает сам хук отрисовки (без нашего шейдера);
        режим 4 — квад со СВОИМ вершинным шейдером (матрица из регистра c4, cModelViewProj): слева цвет вершин;
        режим 5 — то же, матрица из регистра c8 (cViewProj).
        Итог проверки в игре: ps_2_b работает, ps_3_0 — нет; стандартный вершинный шейдер не передаёт цвет.
        20b / 30 — вариант шейдера (ps_2_b по умолчанию, ps_3_0 — для проверки).
      aether_shader_test off — выключить.
]]

local AetherGas = AetherGas
AetherGas.Shader = AetherGas.Shader or {}
local SH = AetherGas.Shader

local mode, scale, variant = nil, 1, "20b"
local mats = {}       -- [variant] = { full = IMaterial, quad = IMaterial }
local WHITE = Material("models/debug/debugwhite")

local function ShaderName(v) return "aether_debug_ps" .. v end

local function Materials(v)
    local m = mats[v]
    if m then return m end
    m = {
        full = CreateMaterial("aether_shader_debug_full_" .. v, "screenspace_general", {
            ["$pixshader"] = ShaderName(v),
            ["$basetexture"] = "_rt_FullFrameFB",
            ["$texture1"] = "_rt_ResolvedFullFrameDepth",
            ["$ignorez"] = 1,
            ["$vertextransform"] = 1,   -- как у шейдеров из Workshop: с 0 полноэкранный квад смещён
            ["$linearwrite"] = 1,
            ["$linearread_basetexture"] = 1,
        }),
        quad = CreateMaterial("aether_shader_debug_quad_" .. v, "screenspace_general", {
            ["$pixshader"] = ShaderName(v),
            ["$basetexture"] = "aether/smoke_puff4",
            ["$texture1"] = "_rt_ResolvedFullFrameDepth",
            ["$vertextransform"] = 1,
            ["$vertexcolor"] = 1,
            ["$linearwrite"] = 1,
        }),
    }
    for reg in pairs({ c4 = true, c8 = true }) do
        m["vs_" .. reg] = CreateMaterial("aether_shader_debug_vs_" .. reg .. "_" .. v, "screenspace_general", {
            ["$pixshader"] = ShaderName(v),
            ["$vertexshader"] = "aether_debug_" .. reg .. "_vs20",
            ["$basetexture"] = "aether/smoke_puff4",
            ["$vertextransform"] = 1,
            ["$vertexcolor"] = 1,
            ["$linearwrite"] = 1,
        })
    end
    mats[v] = m
    return m
end

local function Say(text)
    chat.AddText(Color(120, 200, 255), "[Aether] ", color_white, text)
    MsgC(Color(120, 200, 255), "[Aether] ", color_white, text .. "\n")
end

--- Есть ли файл шейдера и создались ли материалы (в чат и консоль).
function SH.Report(v)
    local m = Materials(v)
    Say(string.format("shader %s: file %s, materials error: full=%s quad=%s, shader=%s",
        ShaderName(v), file.Exists("shaders/fxc/" .. ShaderName(v) .. ".vcs", "GAME") and "found" or "MISSING",
        tostring(m.full:IsError()), tostring(m.quad:IsError()), m.full:GetShader()))
end

concommand.Add("aether_shader_test", function(_, _, args)
    local a = args[1]
    if a == nil or a == "off" then
        mode = nil
        Say("shader test off")
        return
    end
    mode = tonumber(a) or 0
    scale = tonumber(args[2] or "") or 1
    variant = (args[3] == "30") and "30" or "20b"
    SH.Report(variant)
    Say("shader test mode " .. mode .. ", variant ps" .. variant .. (mode == 0 and (", depth scale " .. scale) or ""))
end, nil, "Aether: diagnose custom shaders: <0 depth|1 quad|2 magenta|3 white|4 vs c4|5 vs c8> [scale] [20b|30]; off")

-- режимы 0, 2, 3: на весь экран
hook.Add("RenderScreenspaceEffects", "AetherGas.Shader.Test", function()
    if mode ~= 0 and mode ~= 2 and mode ~= 3 then return end
    if mode == 3 then
        render.SetMaterial(WHITE)
        render.DrawScreenQuad()
        return
    end
    local m = Materials(variant).full
    render.UpdateFullScreenDepthTexture()
    m:SetFloat("$c0_x", mode)
    m:SetFloat("$c0_y", scale)
    m:SetFloat("$c0_z", 1 / ScrW())
    m:SetFloat("$c0_w", 1 / ScrH())
    render.SetMaterial(m)
    render.DrawScreenQuad()
end)

-- режимы 1, 4, 5: квад 40×40 в 70 юнитах перед камерой (4, 5 — со своим вершинным шейдером)
local Q = Vector(0, 0, 0)
-- углы квада: смещение (r, u), цвет вершины, UV
local corners = { { -1, -1, 255, 0, 0, 0, 1 }, { 1, -1, 0, 255, 0, 1, 1 }, { 1, 1, 0, 0, 255, 1, 0 }, { -1, 1, 255, 255, 255, 0, 0 } }
hook.Add("PostDrawTranslucentRenderables", "AetherGas.Shader.Test", function(depth, sky)
    if (mode ~= 1 and mode ~= 4 and mode ~= 5) or depth or sky then return end
    local set = Materials(variant)
    local m = mode == 4 and set.vs_c4 or mode == 5 and set.vs_c8 or set.quad
    render.UpdateFullScreenDepthTexture()
    m:SetFloat("$c0_x", 1)
    m:SetFloat("$c0_z", 1 / ScrW())
    m:SetFloat("$c0_w", 1 / ScrH())
    local eye, ang = EyePos(), EyeAngles()
    local f, r, u = ang:Forward(), ang:Right(), ang:Up()
    local c = eye + f * 70
    render.SetMaterial(m)
    mesh.Begin(MATERIAL_QUADS, 1)
    for i = 1, 4 do
        local k = corners[i]
        Q:Set(c + r * (k[1] * 20) + u * (k[2] * 20))
        mesh.Position(Q)
        mesh.Color(k[3], k[4], k[5], 255)
        mesh.TexCoord(0, k[6], k[7])
        mesh.AdvanceVertex()
    end
    mesh.End()
end)
