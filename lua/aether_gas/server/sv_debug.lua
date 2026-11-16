-- lua/aether_gas/server/sv_debug.lua
--[[
    Отладка сетки через debugoverlay (сервер). Видно только хосту listen-сервера / одиночной игры
    при developer 1: на выделенном сервере debugoverlay клиентам не передаётся.

      aether_debug_grid 1|2           — живая визуализация вокруг хоста (обновление 4 раза в секунду):
          красные пластины   — грань закрыта статикой BSP (SOLID_WORLD, навсегда)
          оранжевые          — грань/центр закрыты динамической сущностью (SOLID_DYNAMIC)
          голубые            — грань упирается в skybox (сток газа)
          бирюзовые линии    — привязки EntToVoxels: воксель → сущность, подпись [MOVING] у движущихся
          жёлтые кубы        — ячейка ждёт перепроверки в RecalcQueue; синие — ленивого запекания
          вспышки            — перепроверка: зелёная — стало открыто, красная — закрыто, белая — без изменений
          белые рамки        — чанки 8×8×8 (ярче — чанк выдан из пула солверу)
          уровень 2 добавляет зелёные линии открытых граней и ячейки внутри стен
      aether_debug_probe [here|x y z] [rebake]  — разбор одного вокселя (по умолчанию — под прицелом)
      aether_debug_bake [радиус] [x y z]        — поставить сферу вокселей в очередь запекания
      aether_debug_stats                        — сводка по кэшу, очередям и трейсам
      aether_debug_reset                        — полный сброс сетки (на сервере и у клиентов)

    Здесь аллокации допустимы: код работает только при включённой отладке.
]]

local AetherGas = AetherGas
local Spatial   = AetherGas.Spatial
local Portals   = AetherGas.Portals
local CV        = AetherGas.CVar
local Debug     = AetherGas.Debug

local band, bor, lshift = bit.band, bit.bor, bit.lshift
local ceil, max, min = math.ceil, math.max, math.min
local IsValid, Entity, Vector, pairs, next = IsValid, Entity, Vector, pairs, next
local format = string.format

local GRID_MASK, GRID_BIAS = Spatial.GRID_MASK, Spatial.GRID_BIAS
local FACE_KNOWN_X, FACE_WORLD_X, FACE_DYN_X, FACE_SKY_X =
    Spatial.FACE_KNOWN_X, Spatial.FACE_WORLD_X, Spatial.FACE_DYN_X, Spatial.FACE_SKY_X
local CELL_KNOWN, SOLID_WORLD, SOLID_DYNAMIC, SOLID_ANY =
    Spatial.CELL_KNOWN, Spatial.SOLID_WORLD, Spatial.SOLID_DYNAMIC, Spatial.SOLID_ANY
local AXIS_STRIDE = Spatial.AXIS_STRIDE
local HIT_NONE, HIT_WORLD, HIT_DYNAMIC, HIT_SKY = Spatial.HIT_NONE, Spatial.HIT_WORLD, Spatial.HIT_DYNAMIC, Spatial.HIT_SKY

local REFRESH        = 0.25
local MAX_OVERLAYS   = 2500
local MAX_BIND_LINES = 160
local PROBE_LIFETIME = 8

local COL_FACE_WORLD   = Color(255, 50, 50, 45)
local COL_FACE_DYN     = Color(255, 150, 0, 80)
local COL_FACE_SKY     = Color(90, 170, 255, 45)
local COL_CELL_WORLD   = Color(120, 20, 20, 25)
local COL_CELL_DYN     = Color(255, 150, 0, 45)
local COL_OPEN_LINK    = Color(70, 255, 110, 255)
local COL_CHUNK        = Color(255, 255, 255, 3)
local COL_CHUNK_ACTIVE = Color(120, 255, 255, 10)
local COL_RECALC       = Color(255, 235, 0, 40)
local COL_PROBEQ       = Color(80, 140, 255, 40)
local COL_BIND         = Color(0, 230, 255, 255)
local COL_FLASH_OPEN   = Color(80, 255, 80, 70)
local COL_FLASH_BLOCK  = Color(255, 60, 60, 70)
local COL_FLASH_SAME   = Color(255, 255, 255, 25)
local COL_TEXT         = Color(230, 240, 255, 255)
local COL_PROBE_OPEN   = Color(80, 255, 80, 30)
local COL_PROBE_SOLID  = Color(255, 60, 60, 30)

local HIT_NAME  = { [HIT_NONE] = "open", [HIT_WORLD] = "WORLD", [HIT_DYNAMIC] = "DYN", [HIT_SKY] = "SKY" }
local HIT_COLOR = { [HIT_WORLD] = COL_FACE_WORLD, [HIT_DYNAMIC] = COL_FACE_DYN, [HIT_SKY] = COL_FACE_SKY }
local DIR_NAME  = { [0] = "+X", "-X", "+Y", "-Y", "+Z", "-Z" }

---------------------------------------------------------------------------------------------------
-- Утилиты
---------------------------------------------------------------------------------------------------
local function Out(ply, msg)
    if IsValid(ply) then ply:PrintMessage(HUD_PRINTCONSOLE, msg .. "\n") else print(msg) end
end

local function CanDebug(ply)
    if not IsValid(ply) then return true end   -- серверная консоль / rcon
    if game.SinglePlayer() or ply:IsSuperAdmin() then return true end
    Out(ply, "[Aether] debug commands are superadmin only")
    return false
end

local function GetHost()
    if game.IsDedicated() then return nil end
    local ply = Entity(1)
    if IsValid(ply) and ply:IsPlayer() then return ply end
    return nil
end

local function Count(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

local function FaceText(f, axis)
    if f == nil or band(f, lshift(FACE_KNOWN_X, axis)) == 0 then return "?" end
    if band(f, lshift(FACE_SKY_X, axis)) ~= 0 then return "SKY" end
    if band(f, lshift(FACE_WORLD_X, axis)) ~= 0 then return "WORLD" end
    if band(f, lshift(FACE_DYN_X, axis)) ~= 0 then return "DYN" end
    return "open"
end

local function CellText(f)
    if f == nil or band(f, CELL_KNOWN) == 0 then return "?" end
    if band(f, SOLID_WORLD) ~= 0 then return "WORLD" end
    if band(f, SOLID_DYNAMIC) ~= 0 then return "DYN" end
    return "open"
end

function Debug.DescribeFlags(f)
    if f == nil then return "not baked" end
    return format("0x%04X  cell=%s  +X=%s  +Y=%s  +Z=%s", f, CellText(f), FaceText(f, 0), FaceText(f, 1), FaceText(f, 2))
end

local function EntLabel(ent)
    if not IsValid(ent) then return "world" end
    return format("#%d %s", ent:EntIndex(), ent:GetClass())
end

---------------------------------------------------------------------------------------------------
-- aether_debug_grid
---------------------------------------------------------------------------------------------------
local lastTraces, lastTime = 0, 0

local function DrawHud(level, drawn, life)
    local pool = Spatial.Pool
    local now = SysTime()
    local traces = Spatial.Stats.traces
    local rate = lastTime > 0 and (traces - lastTraces) / (now - lastTime) or 0
    lastTraces, lastTime = traces, now

    local lines = {
        format("Aether debug L%d | voxel %du | pool %d/%d chunks (high-water %d)",
            level, Spatial.VoxelSize, pool.used, CV.MaxChunks:GetInt(), pool.highWater),
        format("cache %d vox | bound ents %d | shattered %d | movers %d | watched doors %d",
            Spatial.CachedCount, Count(Portals.EntToVoxels), Count(Portals.ShatteredSurfaces),
            Count(Portals.Movers), Count(Portals.WatchedDoors)),
        format("recalc queue %d (<= %d traces/tick) | probe queue %d (<= %d traces/tick)",
            Portals.RecalcQ.count, AetherGas.Const.RECALC_TRACES_PER_TICK, Spatial.ProbeQ.count, CV.ProbeBudget:GetInt()),
        format("traces %.0f/s (total %d) | rebakes %d | overlays %d",
            rate, traces, Portals.Stats.rebaked, drawn),
        format("solver %.2f ms/tick (budget %.2f) | chunks stepped %d | gas cells %d | sources %d | ignite queue %d",
            AetherGas.Solver.Stats.stepMs, CV.TickBudget:GetFloat(), AetherGas.Solver.Stats.chunks,
            AetherGas.Solver.Stats.cells, Count(AetherGas.Solver.Sources), AetherGas.Solver.IgniteQ.count),
    }
    for i = 1, #lines do
        debugoverlay.ScreenText(0.012, 0.30 + i * 0.022, lines[i], life, COL_TEXT)
    end
end

local function DrawGrid()
    local level = CV.DebugGrid:GetInt()
    local host = GetHost()
    if level <= 0 or not host then return end

    local life   = REFRESH + 0.03
    local s      = Spatial.VoxelSize
    local half   = s * 0.5
    local radius = CV.DebugRadius:GetFloat()
    local rCells = ceil(radius / s)
    local radiusSq = radius * radius

    local eye = host:EyePos()
    Debug.Eye, Debug.RadiusSq = eye, radiusSq
    local ex, ey, ez = eye.x, eye.y, eye.z
    local cgx, cgy, cgz = Spatial.WorldToGrid(ex, ey, ez)

    local Collision = Spatial.Collision
    local recalcSet = Portals.RecalcQ.set
    local probeSet  = Spatial.ProbeQ.set

    local plate = half * 0.85
    local faceMins = { [0] = Vector(-0.5, -plate, -plate), Vector(-plate, -0.5, -plate), Vector(-plate, -plate, -0.5) }
    local faceMaxs = { [0] = Vector(0.5, plate, plate), Vector(plate, 0.5, plate), Vector(plate, plate, 0.5) }
    local cellMax  = Vector(s * 0.15, s * 0.15, s * 0.15)
    local cellMin  = -cellMax
    local qMax     = Vector(s * 0.45, s * 0.45, s * 0.45)
    local qMin     = -qMax
    local pMax     = Vector(s * 0.3, s * 0.3, s * 0.3)
    local pMin     = -pMax

    local drawn  = 0
    local chunks = {}

    local function Plate(x, y, z, axis, sign, col)
        local o = half * sign
        debugoverlay.Box(Vector(x + (axis == 0 and o or 0), y + (axis == 1 and o or 0), z + (axis == 2 and o or 0)),
            faceMins[axis], faceMaxs[axis], life, col)
        drawn = drawn + 1
    end

    for gz = max(cgz - rCells, 0), min(cgz + rCells, GRID_MASK) do
        local z = (gz - GRID_BIAS + 0.5) * s
        local dz = z - ez
        for gy = max(cgy - rCells, 0), min(cgy + rCells, GRID_MASK) do
            local y = (gy - GRID_BIAS + 0.5) * s
            local dy = y - ey
            for gx = max(cgx - rCells, 0), min(cgx + rCells, GRID_MASK) do
                local key = bor(gx, lshift(gy, 10), lshift(gz, 20))
                local f = Collision[key]
                if f ~= nil and drawn < MAX_OVERLAYS then
                    local x = (gx - GRID_BIAS + 0.5) * s
                    local dx = x - ex
                    if dx * dx + dy * dy + dz * dz <= radiusSq then
                        chunks[(Spatial.ChunkOf(key))] = true
                        local center = Vector(x, y, z)

                        if band(f, SOLID_WORLD) ~= 0 then
                            if level >= 2 then
                                debugoverlay.Box(center, cellMin, cellMax, life, COL_CELL_WORLD)
                                drawn = drawn + 1
                            end
                        else
                            if band(f, SOLID_DYNAMIC) ~= 0 then
                                debugoverlay.Box(center, cellMin, cellMax, life, COL_CELL_DYN)
                                drawn = drawn + 1
                            end
                            for axis = 0, 2 do
                                -- Своя грань (+ось)
                                if band(f, lshift(FACE_KNOWN_X, axis)) ~= 0 then
                                    if band(f, lshift(FACE_SKY_X, axis)) ~= 0 then
                                        Plate(x, y, z, axis, 1, COL_FACE_SKY)
                                    elseif band(f, lshift(FACE_WORLD_X, axis)) ~= 0 then
                                        Plate(x, y, z, axis, 1, COL_FACE_WORLD)
                                    elseif band(f, lshift(FACE_DYN_X, axis)) ~= 0 then
                                        Plate(x, y, z, axis, 1, COL_FACE_DYN)
                                    elseif level >= 2 then
                                        debugoverlay.Line(center, Vector(x + (axis == 0 and s or 0),
                                            y + (axis == 1 and s or 0), z + (axis == 2 and s or 0)), life, COL_OPEN_LINK, false)
                                        drawn = drawn + 1
                                    end
                                end
                                -- Грань −ось принадлежит соседу; если сосед внутри стены, сам он её не нарисует.
                                local nf = Collision[key - AXIS_STRIDE[axis]]
                                if nf ~= nil and band(nf, SOLID_WORLD) ~= 0 then
                                    Plate(x, y, z, axis, -1, COL_FACE_WORLD)
                                end
                            end
                        end

                        if recalcSet[key] then
                            debugoverlay.Box(center, qMin, qMax, life, COL_RECALC)
                            drawn = drawn + 1
                        end
                        if probeSet[key] then
                            debugoverlay.Box(center, pMin, pMax, life, COL_PROBEQ)
                            drawn = drawn + 1
                        end
                    end
                end
            end
        end
    end

    -- Чанки: все, в которых есть закэшированные воксели рядом, плюс выданные солверу.
    local pool = Spatial.Pool
    for slot = 1, pool.highWater do
        local ck = pool.slotKey[slot]
        if ck ~= -1 then chunks[ck] = true end
    end
    local chunkMaxs = Vector(s * 8, s * 8, s * 8)
    local chunkReach = (radius + s * 8) * (radius + s * 8)
    for ck in pairs(chunks) do
        local ox, oy, oz = Spatial.ChunkOrigin(ck)
        local cx, cy, cz = ox + s * 4 - ex, oy + s * 4 - ey, oz + s * 4 - ez
        if cx * cx + cy * cy + cz * cz <= chunkReach then
            debugoverlay.Box(Vector(ox, oy, oz), vector_origin, chunkMaxs, life,
                pool.chunkSlot[ck] and COL_CHUNK_ACTIVE or COL_CHUNK)
            drawn = drawn + 1
        end
    end

    -- Привязки EntToVoxels
    local lines = 0
    for idx, bucket in pairs(Portals.EntToVoxels) do
        local ent = Entity(idx)
        if IsValid(ent) and next(bucket) ~= nil then
            local ec = ent:WorldSpaceCenter()
            if ec:DistToSqr(eye) <= radiusSq * 4 then
                local count = 0
                for key in pairs(bucket) do
                    count = count + 1
                    if lines < MAX_BIND_LINES then
                        local x, y, z = Spatial.VoxelCenter(key)
                        debugoverlay.Line(Vector(x, y, z), ec, life, COL_BIND, true)
                        lines = lines + 1
                    end
                end
                debugoverlay.Text(ec, format("#%d %s -> %d vox%s", idx, ent:GetClass(), count,
                    Portals.Movers[idx] and " [MOVING]" or ""), life, false)
            end
        end
    end

    DrawHud(level, drawn + lines, life)
end

--- Вспышка перепроверки (вызывается из очереди RecalcQueue, только пока отладка включена).
local function OnRebake(key, before, after)
    local eye = Debug.Eye
    if not eye then return end
    local x, y, z = Spatial.VoxelCenter(key)
    local dx, dy, dz = x - eye.x, y - eye.y, z - eye.z
    if dx * dx + dy * dy + dz * dz > (Debug.RadiusSq or 0) then return end

    local h = Spatial.VoxelSize * 0.48
    local col
    if before == after then
        col = COL_FLASH_SAME
    elseif band(after, Spatial.FACE_WORLD_ALL + Spatial.FACE_DYN_ALL + SOLID_ANY) ~= 0 then
        col = COL_FLASH_BLOCK
    else
        col = COL_FLASH_OPEN
    end
    debugoverlay.Box(Vector(x, y, z), Vector(-h, -h, -h), Vector(h, h, h), 0.6, col)
end

local function ApplyDebugState()
    if CV.DebugGrid:GetInt() > 0 then
        timer.Create("AetherGas.Debug.Grid", REFRESH, 0, DrawGrid)
        Debug.OnRebake = OnRebake
        if GetConVar("developer"):GetInt() < 1 then
            print("[Aether] aether_debug_grid is on, but developer = 0, so debugoverlay draws nothing. Type: developer 1")
        end
        if game.IsDedicated() then
            print("[Aether] aether_debug_grid: debugoverlay is not visible to clients of a dedicated server, use a listen server")
        end
    else
        timer.Remove("AetherGas.Debug.Grid")
        Debug.OnRebake = nil
        Debug.Eye = nil
    end
end

cvars.AddChangeCallback("aether_debug_grid", ApplyDebugState, "AetherGas.Debug")
ApplyDebugState()

---------------------------------------------------------------------------------------------------
-- aether_debug_probe [here | x y z] [rebake]
---------------------------------------------------------------------------------------------------
concommand.Add("aether_debug_probe", function(ply, _, args)
    if not CanDebug(ply) then return end

    local s = Spatial.VoxelSize
    local x, y, z
    local ax, ay, az = tonumber(args[1]), tonumber(args[2]), tonumber(args[3])
    if ax and ay and az then
        x, y, z = ax, ay, az
    elseif not IsValid(ply) then
        Out(ply, "[Aether] from the server console: aether_debug_probe <x> <y> <z> [rebake]")
        return
    elseif args[1] == "here" then
        local p = ply:WorldSpaceCenter()
        x, y, z = p.x, p.y, p.z
    else
        -- Отступаем от поверхности на полвокселя, чтобы взять ячейку перед стеной, а не в ней.
        local tr = ply:GetEyeTrace()
        local p = tr.HitPos + tr.HitNormal * (s * 0.5)
        x, y, z = p.x, p.y, p.z
    end

    local rebake = false
    for i = 1, #args do
        if args[i] == "rebake" then rebake = true end
    end

    local key = Spatial.WorldToVoxel(x, y, z)
    if not key then
        Out(ply, format("[Aether] point (%.0f %.0f %.0f) is outside the grid", x, y, z))
        return
    end

    local gx, gy, gz = Spatial.UnpackKey(key)
    local chunkKey, li = Spatial.ChunkOf(key)
    local cx, cy, cz = Spatial.VoxelCenter(key)
    local center = Vector(cx, cy, cz)
    local f = Spatial.Collision[key]

    Out(ply, format("[Aether] voxel key=%d grid=(%d %d %d) chunk=%d li=%d center=(%.1f %.1f %.1f) size=%d%s",
        key, gx, gy, gz, chunkKey, li, cx, cy, cz, s, Spatial.IsBorder(key) and " [GRID BORDER]" or ""))
    Out(ply, "  cache:  " .. Debug.DescribeFlags(f))

    -- Свежие трейсы (кэш не меняется): центр + все 6 граней. Грань −ось трассируется от соседа-владельца.
    local cellHit, cellEnt = Spatial.TraceCell(key)
    Out(ply, format("  trace:  cell=%s%s", HIT_NAME[cellHit], cellHit == HIT_DYNAMIC and (" " .. EntLabel(cellEnt)) or ""))

    local h = s * 0.5
    debugoverlay.Box(center, Vector(-h, -h, -h), Vector(h, h, h), PROBE_LIFETIME,
        cellHit == HIT_NONE and COL_PROBE_OPEN or COL_PROBE_SOLID)
    debugoverlay.Text(center, format("key %d (%d,%d,%d)", key, gx, gy, gz), PROBE_LIFETIME, false)

    local plate = h * 0.85
    for dir = 0, 5 do
        local axis = bit.rshift(dir, 1)
        local negative = band(dir, 1) == 1
        local owner = negative and (key - AXIS_STRIDE[axis]) or key
        local hit, ent = Spatial.TraceFace(owner, axis)
        local cached = FaceText(Spatial.Collision[owner], axis)
        local fresh = HIT_NAME[hit]
        local note = (cached ~= "?" and cached ~= fresh) and "   <-- DIFFERS FROM CACHE" or ""
        Out(ply, format("  %s: trace=%-5s cache=%-5s%s%s", DIR_NAME[dir], fresh, cached,
            hit == HIT_DYNAMIC and (" " .. EntLabel(ent)) or "", note))

        local o = negative and -h or h
        local pos = Vector(cx + (axis == 0 and o or 0), cy + (axis == 1 and o or 0), cz + (axis == 2 and o or 0))
        local pm = Vector(axis == 0 and 0.5 or plate, axis == 1 and 0.5 or plate, axis == 2 and 0.5 or plate)
        if hit == HIT_NONE then
            debugoverlay.Line(center, pos, PROBE_LIFETIME, COL_OPEN_LINK, true)
        else
            debugoverlay.Box(pos, -pm, pm, PROBE_LIFETIME, HIT_COLOR[hit])
        end
        if hit == HIT_DYNAMIC and IsValid(ent) then
            debugoverlay.Line(pos, ent:WorldSpaceCenter(), PROBE_LIFETIME, COL_BIND, true)
        end
    end

    local binds = {}
    for idx, bucket in pairs(Portals.EntToVoxels) do
        if bucket[key] then binds[#binds + 1] = EntLabel(Entity(idx)) end
    end
    Out(ply, "  bindings: " .. (#binds > 0 and table.concat(binds, ", ") or "no"))
    Out(ply, format("  queues: recalc=%s  probe=%s",
        Portals.RecalcQ.set[key] and "yes" or "no", Spatial.ProbeQ.set[key] and "yes" or "no"))

    if rebake then
        -- Сама ячейка и три соседа-владельца её отрицательных граней.
        local owners = { key, key - 1, key - Spatial.Y_STRIDE, key - Spatial.Z_STRIDE }
        local queued = 0
        for i = 1, #owners do
            local k = owners[i]
            if k >= 0 then
                if Spatial.Collision[k] ~= nil then
                    if Portals.InvalidateVoxel(k) then queued = queued + 1 end
                elseif Spatial.RequestProbe(k) then
                    queued = queued + 1
                end
            end
        end
        Out(ply, format("  rebake: queued %d cells", queued))
    end
end, nil, "Aether: inspect the voxel at aim. Arguments: [here | x y z] [rebake]")

---------------------------------------------------------------------------------------------------
-- aether_debug_bake [радиус] [x y z]
-- На этапе 1 солвера ещё нет и кэш сам не наполняется — команда запекает сферу вокруг игрока.
---------------------------------------------------------------------------------------------------
concommand.Add("aether_debug_bake", function(ply, _, args)
    if not CanDebug(ply) then return end

    local radius = math.Clamp(tonumber(args[1]) or 400, 40, 1200)
    local x, y, z
    local ax, ay, az = tonumber(args[2]), tonumber(args[3]), tonumber(args[4])
    if ax and ay and az then
        x, y, z = ax, ay, az
    elseif IsValid(ply) then
        local e = ply:EyePos()
        x, y, z = e.x, e.y, e.z
    else
        Out(ply, "[Aether] from the server console: aether_debug_bake <radius> <x> <y> <z>")
        return
    end

    local s = Spatial.VoxelSize
    local gx0, gy0, gz0 = Spatial.WorldToGrid(x, y, z)
    local r = ceil(radius / s)
    local rr = (radius / s) ^ 2
    local queued = 0

    for dz = -r, r do
        local gz = gz0 + dz
        if gz >= 0 and gz <= GRID_MASK then
            for dy = -r, r do
                local gy = gy0 + dy
                if gy >= 0 and gy <= GRID_MASK then
                    for dx = -r, r do
                        local gx = gx0 + dx
                        if gx >= 0 and gx <= GRID_MASK and dx * dx + dy * dy + dz * dz <= rr then
                            if Spatial.RequestProbe(Spatial.PackKey(gx, gy, gz)) then queued = queued + 1 end
                        end
                    end
                end
            end
        end
    end

    local budget = CV.ProbeBudget:GetInt()
    Out(ply, format("[Aether] queued for baking: %d voxels (up to %d traces; budget %d/tick, about %.1f s)",
        queued, queued * 4, budget, queued * 4 / budget * engine.TickInterval()))
end, nil, "Aether: bake collision in a sphere. Arguments: [radius=400] [x y z]")

---------------------------------------------------------------------------------------------------
-- aether_debug_stats / aether_debug_reset
---------------------------------------------------------------------------------------------------
concommand.Add("aether_debug_stats", function(ply)
    if not CanDebug(ply) then return end
    local pool, st, ps = Spatial.Pool, Spatial.Stats, Portals.Stats
    Out(ply, format("[Aether] v%s | voxel %du | grates block: %s | registry crc %s (%d gases)",
        AetherGas.Version, Spatial.VoxelSize, tostring(Spatial.GratesBlock), tostring(AetherGas.RegistryChecksum), AetherGas.GasCount))
    Out(ply, format("  collision cache: %d voxels | traces total %d | bakes %d | rechecks %d",
        Spatial.CachedCount, st.traces, st.probes, st.rebakes))
    Out(ply, format("  pool: %d/%d chunks, high-water %d, SoA fields %d",
        pool.used, CV.MaxChunks:GetInt(), pool.highWater, #pool.fieldNames))
    Out(ply, format("  portals: bound entities %d | broken glass %d | moving %d | watched doors %d",
        Count(Portals.EntToVoxels), Count(Portals.ShatteredSurfaces), Count(Portals.Movers), Count(Portals.WatchedDoors)))
    Out(ply, format("  queues: recalc %d | probe %d | events %d | invalidated %d | recheck traces %d",
        Portals.RecalcQ.count, Spatial.ProbeQ.count, ps.events, ps.invalidated, ps.traces))
end, nil, "Aether: cache, queue and trace summary")

concommand.Add("aether_debug_reset", function(ply)
    if not CanDebug(ply) then return end
    Spatial.Rebuild(Spatial.VoxelSize, Spatial.GratesBlock)
    Spatial.BroadcastGridReset()
    Out(ply, "[Aether] grid reset on the server and all clients")
end, nil, "Aether: fully reset the collision cache and chunk pool")
