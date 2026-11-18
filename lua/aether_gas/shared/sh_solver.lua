-- lua/aether_gas/shared/sh_solver.lua
--[[
    Солвер газа (shared): клеточный автомат с консервативным попарным обменом.

    Модель ячейки: один газ (Gas = id), концентрация Conc ∈ [0, MAX_CONC] (> 1 — избыточное давление
    у источника, рендер и урон обрезают до 1), температура Temp (°C), импульс VelX/Y/Z (юнит/с).

    Шаг ячейки (только непустые, «толкают» вниз по градиенту, масса сохраняется точно):
      k      = (diffusion + spread·min(c,1))·dt          — диффузия + выравнивание давления (flood fill):
                                                            плотный газ расталкивается быстрее
      поток  = k·(c − max(c_n, cohesion))                — по каждой открытой грани (FaceState); cohesion
                                                            держит у дыма плотный объём с краем (как в CS2)
      ρ_eff  = density·T_amb/T,  buoy = 1 − ρ_eff        — плавучесть идеального газа
      вверх  : поток·clamp(1+2·buoy) + BUOY_RATE·buoy·c·dt   (лёгкий/горячий газ всплывает)
      вниз   : поток·clamp(1−2·buoy) + BUOY_RATE·(−buoy)·c·dt (тяжёлый стекает и не лезет вверх)
      адвекция: max(0, v·n)·dt/size·c                    — импульс взрывов и ветер (снаружи)
      утечка : COH_LEAK·dt·(c − c_n)                     — край облака со временем расплывается в дымку
      давление: избыток e = max(0, c − 1) толкает газ PRESS_RATE·dt·(e − e_n) по каждой открытой грани
                и разгоняет ячейку PRESS_ACCEL·dt·(e − e_n) вдоль грани — полная комната выдавливает газ
                струёй в дверь; чужой газ у грани получает тот же толчок (вытеснение)
      небо   : поток в грань со skybox просто уходит (сток в атмосферу)
    Затем: распад decay (в помещении × indoorDecay, на улице + OUTDOOR_DECAY), конденсация у стен (пар),
    остывание, затухание импульса. Источник, упёршийся в MAX_CONC, переливает излишек в соседние ячейки.

    Обход in-place (Гаусс–Зейдель) с чередованием направления от шага к шагу — без второго буфера и без
    рассинхрона между чанками, обновляемыми в разные тики. Порядковая асимметрия гасится чередованием.

    Time-slicing: курсор идёт по слотам пула, каждый чанк получает свой dt = now − lastStep
    (не чаще MIN_DT, не больше MAX_DT), пока не исчерпан бюджет aether_tick_budget (SysTime).

    Сеть: клиент считает тот же солвер сам. Сервер рассылает только события (источник, стоп,
    туннель пули, взрыв, поджиг, очистка) — облака не передаются никогда. Полный детерминизм при
    разном time-slicing недостижим; расхождения со временем — задача дельт-чексумм (sv_network).
    Урон, взрывы и эффекты — только на сервере.

    Нулевые аллокации в цикле: числа, плоские массивы пула, upvalue-функции без замыканий.
]]

local AetherGas = AetherGas
AetherGas.Solver = AetherGas.Solver or {}
local Solver  = AetherGas.Solver
local Spatial = AetherGas.Spatial
local C       = AetherGas.Const
local CV      = AetherGas.CVar
local P       = AetherGas.GasParams

local band, bor, lshift, rshift = bit.band, bit.bor, bit.lshift, bit.rshift
local floor, abs, min, max, sqrt = math.floor, math.abs, math.min, math.max, math.sqrt
local CurTime, SysTime = CurTime, SysTime
local pairs = pairs

local Pool       = Spatial.Pool
local Collision  = Spatial.Collision
local Gas, Conc, Temp = Spatial.Gas, Spatial.Conc, Spatial.Temp
local VelX, VelY, VelZ = Spatial.VelX, Spatial.VelY, Spatial.VelZ
local chunkSlot, slotKey, slotDirty, slotCount = Pool.chunkSlot, Pool.slotKey, Pool.slotDirty, Pool.slotCount

local Pdens, Pdiff, Pspread, Pdecay, Pcoh = P.Density, P.Diffusion, P.Spread, P.Decay, P.Cohesion
local Pcool, Pcond, PcondT, PinDecay = P.Cooling, P.CondenseRate, P.CondenseTemp, P.IndoorDecay
local PflameMin, PflameMax, Pblast = P.FlameMin, P.FlameMax, P.BlastDamage

local RequestProbe = Spatial.RequestProbe
local QueuePush, QueuePop = Spatial.QueuePush, Spatial.QueuePop
local DIR_STRIDE, AXIS_STRIDE = Spatial.DIR_STRIDE, Spatial.AXIS_STRIDE
local GRID_MASK, GRID_BIAS, Z_STRIDE = Spatial.GRID_MASK, Spatial.GRID_BIAS, Spatial.Z_STRIDE

local CELL_KNOWN, SOLID_ANY = Spatial.CELL_KNOWN, Spatial.SOLID_ANY
local FACE_KNOWN_X, FACE_BLOCK_X, FACE_SKY_X = Spatial.FACE_KNOWN_X, Spatial.FACE_BLOCK_X, Spatial.FACE_SKY_X

---------------------------------------------------------------------------------------------------
-- Константы модели
---------------------------------------------------------------------------------------------------
local MAX_CONC      = 3.0    -- избыточное давление у источника; всё, что > 1, «рвётся» наружу сильнее
local EPS           = 0.003  -- ниже — ячейка очищается
local OVERWRITE     = 0.02   -- чужой газ слабее этого вытесняется, сильнее — блокирует обмен
local MIN_DT        = 0.05   -- чанк не шагает чаще 20 Гц
local MAX_DT        = 0.25   -- после долгой паузы шаг обрезается (устойчивость явной схемы)
local MAX_K         = 0.15   -- предел доли обмена на грань за шаг (6·0.15 < 1 — схема устойчива)
local FLOW_CAP      = 0.45   -- в одну грань уходит не больше этой доли остатка
local BUOY_RATE     = 1.2    -- 1/с, сила всплытия/оседания на единицу |buoy|
local VEL_DAMP      = 2.5    -- 1/с, затухание импульса
local OUTDOOR_DECAY = 0.04   -- 1/с, доп. рассеивание под открытым небом
local COH_LEAK      = 0.008  -- 1/с, утечка сквозь когезию: облако держится ~полминуты, за 3–4 мин расплывается дымкой
local PRESS_RATE    = 1.6    -- 1/с, перенос избыточного давления (c > 1) через грань
local PRESS_ACCEL   = 260    -- юнит/с² на единицу перепада избытка: разгон струи из переполненного объёма
local PUSH_FOREIGN  = 0.6    -- доля разгона, передаваемая чужому газу у грани (вытеснение)
local RELEASE_DELAY = 1.0    -- пустой чанк возвращается в пул через секунду
local AMB           = C.AMBIENT_TEMP
local KELVIN        = C.KELVIN
local AMB_K         = AMB + KELVIN

-- Смещение индекса соседа внутри чанка: +X, −X, +Y, −Y, +Z, −Z
local LOCAL_OFF = { [0] = 1, -1, 8, -8, 64, -64 }

-- Детонация
local MAX_DETONATIONS_PER_TICK = 48
local MAX_BLASTDAMAGE_PER_TICK = 10
local MAX_EFFECTS_PER_TICK     = 4
local MAX_TUNNELS_PER_TICK     = 24
-- Пуля оставляет (1 − aether_tunnel_strength) газа на пути (по умолчанию 15 %); диффузия затягивает за ~1.5–2.5 с

-- Состояние (переживает lua refresh)
Solver.LastStep     = Solver.LastStep or {}     -- [slot] = CurTime последнего шага
Solver.EmptySince   = Solver.EmptySince or {}   -- [slot] = CurTime, с которого чанк пуст
Solver.Parity       = Solver.Parity or {}       -- [slot] = направление обхода
Solver.Outdoor      = Solver.Outdoor or {}      -- [chunkKey] = 1 (под небом) / 0
Solver.Sources      = Solver.Sources or {}      -- [id] = источник
Solver.NextSourceId = Solver.NextSourceId or 1
Solver.IgniteQ      = Solver.IgniteQ or Spatial.QueueNew(512)
Solver.Stats        = Solver.Stats or { stepMs = 0, chunks = 0, cells = 0 }
Solver.WindX, Solver.WindY = Solver.WindX or 0, Solver.WindY or 0
Solver.FlammableSeen = Solver.FlammableSeen or -100

local LastStep, EmptySince, Parity, Outdoor = Solver.LastStep, Solver.EmptySince, Solver.Parity, Solver.Outdoor
local Sources, IgniteQ, Stats = Solver.Sources, Solver.IgniteQ, Solver.Stats

local EV_SOURCE, EV_STOP, EV_TUNNEL, EV_BLAST, EV_IGNITE, EV_CLEAR, EV_PUSH, EV_PUFF = 0, 1, 2, 3, 4, 5, 6, 7

---------------------------------------------------------------------------------------------------
-- Улица / помещение: один трейс вверх на чанк за всю жизнь карты
---------------------------------------------------------------------------------------------------
local OutStart, OutEnd, OutRes = Vector(0, 0, 0), Vector(0, 0, 0), {}
local OutTrace = { start = OutStart, endpos = OutEnd, mask = MASK_SOLID_BRUSHONLY, output = OutRes }

local function ProbeOutdoor(chunkKey)
    local ox, oy, oz = Spatial.ChunkOrigin(chunkKey)
    local s = Spatial.VoxelSize
    OutStart:SetUnpacked(ox + s * 4, oy + s * 4, oz + s * 7.5)
    OutEnd:SetUnpacked(ox + s * 4, oy + s * 4, 32768)
    util.TraceLine(OutTrace)
    return (OutRes.HitSky and not OutRes.StartSolid) and 1 or 0
end

---------------------------------------------------------------------------------------------------
-- Доступ к ячейкам
---------------------------------------------------------------------------------------------------
local function SlotFor(chunkKey, create)
    local slot = chunkSlot[chunkKey]
    if slot or not create then return slot end
    slot = Spatial.AcquireChunk(chunkKey)
    if slot then
        LastStep[slot] = CurTime()
        EmptySince[slot] = nil
        if Outdoor[chunkKey] == nil then Outdoor[chunkKey] = ProbeOutdoor(chunkKey) end
    end
    return slot
end

--- voxelKey → индекс в полях пула и слот (nil — чанка нет и create = false, либо пул исчерпан).
local function KeyIndex(key, create)
    local ck = bor(band(rshift(key, 3), 127), lshift(band(rshift(key, 13), 127), 7), lshift(band(rshift(key, 23), 127), 14))
    local slot = SlotFor(ck, create)
    if not slot then return nil, nil end
    local li = bor(band(key, 7), lshift(band(rshift(key, 10), 7), 3), lshift(band(rshift(key, 20), 7), 6))
    return lshift(slot - 1, 9) + li + 1, slot
end
Solver.KeyIndex = KeyIndex

local function ClearCell(idx, slot)
    if Gas[idx] ~= 0 then slotCount[slot] = slotCount[slot] - 1 end
    Gas[idx], Conc[idx], Temp[idx] = 0, 0, AMB
    VelX[idx], VelY[idx], VelZ[idx] = 0, 0, 0
    slotDirty[slot] = true
end

--- Добавляет amount газа g в ячейку. Возвращает реально добавленное (ёмкость, чужой газ).
local function Fill(idx, slot, g, amount, t, vx, vy, vz)
    local cur = Conc[idx]
    if Gas[idx] ~= g then
        if cur > OVERWRITE then return 0 end
        if Gas[idx] == 0 then slotCount[slot] = slotCount[slot] + 1 end
        Gas[idx], cur = g, 0
        Temp[idx], VelX[idx], VelY[idx], VelZ[idx] = t, vx, vy, vz
    end
    local room = MAX_CONC - cur
    if amount > room then amount = room end
    if amount <= 0 then return 0 end
    local nc = cur + amount
    local w = amount / nc                       -- смешение по массе
    Temp[idx] = Temp[idx] + (t - Temp[idx]) * w
    VelX[idx] = VelX[idx] + (vx - VelX[idx]) * w
    VelY[idx] = VelY[idx] + (vy - VelY[idx]) * w
    VelZ[idx] = VelZ[idx] + (vz - VelZ[idx]) * w
    Conc[idx] = nc
    slotDirty[slot] = true
    EmptySince[slot] = nil
    return amount
end

---------------------------------------------------------------------------------------------------
-- Шаг ячейки
---------------------------------------------------------------------------------------------------
local function StepCell(idx, slot, li, key, f, g, c, dt, outdoor, s)
    local T = Temp[idx]
    local tK = T + KELVIN
    if tK < 50 then tK = 50 end
    local buoy = 1 - Pdens[g] * AMB_K / tK

    local k = (Pdiff[g] + Pspread[g] * (c < 1 and c or 1)) * dt
    if k > MAX_K then k = MAX_K end
    local upScale = 1 + 2 * buoy
    if upScale < 0 then upScale = 0 elseif upScale > 1 then upScale = 1 end
    local downScale = 1 - 2 * buoy
    if downScale < 0 then downScale = 0 elseif downScale > 1 then downScale = 1 end
    local drift = BUOY_RATE * dt * c
    local adv = dt / s * c
    local coh = Pcoh[g]

    local vx, vy, vz = VelX[idx], VelY[idx], VelZ[idx]
    if outdoor then vx, vy = vx + Solver.WindX, vy + Solver.WindY end

    local lx, ly, lz = band(li, 7), band(rshift(li, 3), 7), rshift(li, 6)
    local remaining = c
    local blocked = 0
    local ex = c > 1 and c - 1 or 0                 -- избыточное давление ячейки
    local leak = COH_LEAK * dt
    local press = PRESS_RATE * dt
    local accel = PRESS_ACCEL * dt
    local ax, ay, az = 0, 0, 0                      -- разгон от перепада давления (пишется после цикла)

    for dir = 0, 5 do
        local axis = rshift(dir, 1)
        local neg = band(dir, 1) == 1
        local fo = f
        local owner = key
        if neg then
            owner = key - AXIS_STRIDE[axis]
            fo = Collision[owner]
        end

        local state
        if fo == nil or band(fo, lshift(FACE_KNOWN_X, axis)) == 0 then
            RequestProbe(owner)
            state = -1
        elseif band(fo, lshift(FACE_BLOCK_X, axis)) == 0 then
            state = 1
        elseif band(fo, lshift(FACE_SKY_X, axis)) ~= 0 then
            state = 2
        else
            state = 0
            blocked = blocked + 1
        end

        if state >= 1 then
            -- Соседняя ячейка: внутри чанка — смещением, на границе — через хэш чанков.
            local nidx, nslot
            if state == 1 then
                local local_ok
                if axis == 0 then local_ok = (neg and lx > 0) or (not neg and lx < 7)
                elseif axis == 1 then local_ok = (neg and ly > 0) or (not neg and ly < 7)
                else local_ok = (neg and lz > 0) or (not neg and lz < 7) end
                if local_ok then
                    nidx, nslot = idx + LOCAL_OFF[dir], slot
                else
                    nidx, nslot = KeyIndex(key + DIR_STRIDE[dir], false)
                end
            end

            local cn = 0
            if nidx then
                if Gas[nidx] == g then
                    cn = Conc[nidx]
                elseif Conc[nidx] > OVERWRITE then
                    cn = -1                     -- чужой плотный газ: обмена нет
                end
            end

            -- Перепад избыточного давления через грань: разгон своей ячейки (струя), а чужой газ за
            -- гранью получает толчок — переполненный объём вытесняет его, а не упирается.
            local dp = ex
            if cn > 1 then dp = ex - (cn - 1) end
            if dp > 0 and state == 1 then
                local a = (neg and -accel or accel) * dp
                if axis == 0 then ax = ax + a elseif axis == 1 then ay = ay + a else az = az + a end
                if cn < 0 then
                    a = a * PUSH_FOREIGN
                    if axis == 0 then VelX[nidx] = VelX[nidx] + a
                    elseif axis == 1 then VelY[nidx] = VelY[nidx] + a
                    else VelZ[nidx] = VelZ[nidx] + a end
                end
            end

            if cn >= 0 then
                -- Когезия: расталкивается только избыток над max(c_n, cohesion) — у облака есть край;
                -- медленная утечка COH_LEAK со временем выравнивает облако в дымку по всему объёму.
                local floorC = cn > coh and cn or coh
                local flow = 0
                if c > floorC then flow = k * (c - floorC) end
                if c > cn then flow = flow + leak * (c - cn) end
                if axis == 2 then
                    if neg then
                        flow = flow * downScale
                        if buoy < 0 then flow = flow - drift * buoy end
                    else
                        flow = flow * upScale
                        if buoy > 0 then flow = flow + drift * buoy end
                    end
                end
                -- давление толкает одинаково во все стороны (тяжёлый газ под напором идёт и вверх);
                -- не больше 40 % перепада — без перехлёста через равновесие
                if dp > 0 then
                    local fp = press * dp
                    if fp > 0.4 * dp then fp = 0.4 * dp end
                    flow = flow + fp
                end
                local v = (axis == 0 and vx) or (axis == 1 and vy) or vz
                if neg then v = -v end
                if v > 0 then flow = flow + v * adv end

                local cap = remaining * FLOW_CAP
                if flow > cap then flow = cap end
                if flow > 1e-5 then
                    if state == 2 then
                        remaining = remaining - flow    -- ушло в небо
                    else
                        if not nidx then nidx, nslot = KeyIndex(key + DIR_STRIDE[dir], true) end
                        if nidx then
                            remaining = remaining - Fill(nidx, nslot, g, flow, T, vx, vy, vz)
                        end
                    end
                end
            end
        end
    end

    -- Распад (в помещении газ почти не исчезает — разбавляется), конденсация, остывание, затухание импульса
    local decay = Pdecay[g]
    if outdoor then decay = decay + OUTDOOR_DECAY else decay = decay * PinDecay[g] end
    local cr = Pcond[g]
    if cr > 0 and blocked > 0 then
        decay = decay + cr * blocked / 6 * (T < PcondT[g] and 1 or 0.25)
    end
    remaining = remaining - remaining * min(1, decay * dt)

    if remaining < EPS then
        ClearCell(idx, slot)
        return
    end
    Conc[idx] = remaining
    Temp[idx] = T + (AMB - T) * min(1, Pcool[g] * dt)
    local damp = 1 - VEL_DAMP * dt
    if damp < 0 then damp = 0 end
    VelX[idx], VelY[idx], VelZ[idx] = (VelX[idx] + ax) * damp, (VelY[idx] + ay) * damp, (VelZ[idx] + az) * damp
    if PflameMin[g] <= 1 then Solver.FlammableSeen = CurTime() end
end

local function StepChunk(slot, dt, now)
    local ck = slotKey[slot]
    local base = lshift(slot - 1, 9)
    -- ключ локальной ячейки (0,0,0): gx = cx·8 → бит 0, gy = cy·8 → бит 10, gz = cz·8 → бит 20
    local keyBase = bor(lshift(band(ck, 127), 3), lshift(band(rshift(ck, 7), 127), 13), lshift(band(rshift(ck, 14), 127), 23))
    local outdoor = Outdoor[ck] == 1
    local s = Spatial.VoxelSize
    local forward = Parity[slot] ~= 1
    Parity[slot] = forward and 1 or 0
    local cells = 0

    for n = 0, 511 do
        local li = forward and n or (511 - n)
        local idx = base + li + 1
        local c = Conc[idx]
        if c > 0 then
            cells = cells + 1
            local key = keyBase + band(li, 7) + band(rshift(li, 3), 7) * 1024 + rshift(li, 6) * 1048576
            local f = Collision[key]
            if f == nil or band(f, CELL_KNOWN) == 0 then
                RequestProbe(key)               -- ждём запекания, газ стоит на месте
            elseif band(f, SOLID_ANY) ~= 0 then
                ClearCell(idx, slot)            -- дверь закрылась на облако: газ вытеснен
            else
                StepCell(idx, slot, li, key, f, Gas[idx], c, dt, outdoor, s)
            end
        end
    end

    Stats.cells = Stats.cells + cells
    if slotCount[slot] <= 0 then
        slotCount[slot] = 0
        local since = EmptySince[slot]
        if not since then
            EmptySince[slot] = now
        elseif now - since > RELEASE_DELAY then
            EmptySince[slot] = nil
            Spatial.ReleaseChunk(ck)
        end
    else
        slotDirty[slot] = true
    end
end

---------------------------------------------------------------------------------------------------
-- Источники
---------------------------------------------------------------------------------------------------
-- Сток (вытяжка): убирает любой газ в шаре радиуса R с линейным спадом и тянет облако к себе.
local SINK_PULL = 220   -- юнит/с на краю зоны
local SinkByGas = {}    -- [id газа] = сколько забрано за вызов (воздуховод переносит преобладающий газ)

--- Возвращает: всего забрано, id преобладающего газа, сколько его забрано.
local function ApplySink(px, py, pz, radius, rate, dt)
    for g = 1, AetherGas.GasCount do SinkByGas[g] = 0 end
    local total = 0
    local s = Spatial.VoxelSize
    local r = math.ceil(radius / s)
    local cgx, cgy, cgz = Spatial.WorldToGrid(px, py, pz)
    local r2 = radius * radius
    for gz = max(cgz - r, 1), min(cgz + r, GRID_MASK - 1) do
        local dz = (gz - GRID_BIAS + 0.5) * s - pz
        for gy = max(cgy - r, 1), min(cgy + r, GRID_MASK - 1) do
            local dy = (gy - GRID_BIAS + 0.5) * s - py
            for gx = max(cgx - r, 1), min(cgx + r, GRID_MASK - 1) do
                local dx = (gx - GRID_BIAS + 0.5) * s - px
                local d2 = dx * dx + dy * dy + dz * dz
                if d2 <= r2 then
                    local idx, slot = KeyIndex(bor(gx, lshift(gy, 10), lshift(gz, 20)), false)
                    if idx and Conc[idx] > 0 then
                        local d = sqrt(d2)
                        local w = 1 - d / radius
                        local before = Conc[idx]
                        local g = Gas[idx]
                        local c = before - rate * dt * w
                        local taken = c < EPS and before or (before - c)
                        total = total + taken
                        SinkByGas[g] = (SinkByGas[g] or 0) + taken
                        if c < EPS then
                            ClearCell(idx, slot)
                        else
                            Conc[idx] = c
                            local pull = SINK_PULL * w / (d + 1)
                            VelX[idx] = VelX[idx] - dx * pull
                            VelY[idx] = VelY[idx] - dy * pull
                            VelZ[idx] = VelZ[idx] - dz * pull
                            slotDirty[slot] = true
                        end
                    end
                end
            end
        end
    end
    local bestG, bestAmt = 0, 0
    for g = 1, AetherGas.GasCount do
        if SinkByGas[g] > bestAmt then bestG, bestAmt = g, SinkByGas[g] end
    end
    return total, bestG, bestAmt
end

local LocalVec = Vector(0, 0, 0)
local KIND_EMIT, KIND_SINK, KIND_BLOW, KIND_DUCT = 0, 1, 2, 3
local BLOW_LENGTH = 520     -- длина струи воздуходувки
local DUCT_OUT_SPEED = 160  -- скорость выпуска из воздуховода, юнит/с
local SPILL_SPEED = 120     -- скорость газа, перелитого из переполненной ячейки источника, юнит/с
local DUCT_HOLD = 6         -- труба вмещает столько газа; полная — впуск перестаёт тянуть (масса сохраняется)
local DUCT_OUT_RATE = 10    -- выпуск отдаёт до стольких единиц/с, раскладывая по 5 ячейкам перед решёткой

--- Возвращает реально добавленное количество (ячейка полна/занята чужим газом/в стене → меньше amount).
local function InjectAt(px, py, pz, g, amount, t, vx, vy, vz)
    local key = Spatial.WorldToVoxel(px, py, pz)
    if not key then return 0 end
    local f = Collision[key]
    if f ~= nil and band(f, CELL_KNOWN) ~= 0 and band(f, SOLID_ANY) ~= 0 then
        key = key + Z_STRIDE           -- точка утоплена в пол/стену — берём ячейку выше
        f = Collision[key]
    end
    if f == nil or band(f, CELL_KNOWN) == 0 then
        RequestProbe(key)
        return 0
    end
    if band(f, SOLID_ANY) ~= 0 then return 0 end
    local idx, slot = KeyIndex(key, true)
    if not idx then return 0 end
    local put = Fill(idx, slot, g, amount, t, vx, vy, vz)
    local rest = amount - put
    if rest < 1e-4 then return put end
    -- Ячейка источника упёрлась в MAX_CONC: излишек переливается в соседей через открытые грани
    -- (с толчком наружу) — источник не теряет массу, а давление вокруг растёт.
    local n = 0
    for dir = 0, 5 do
        if Spatial.FaceState(key, dir) == 1 then n = n + 1 end
    end
    if n == 0 then return put end
    local share = rest / n
    for dir = 0, 5 do
        if Spatial.FaceState(key, dir) == 1 then
            local nkey = key + DIR_STRIDE[dir]
            local nf = Collision[nkey]
            if nf ~= nil and band(nf, CELL_KNOWN) ~= 0 and band(nf, SOLID_ANY) == 0 then
                local nidx, nslot = KeyIndex(nkey, true)
                if nidx then
                    local axis, sign = rshift(dir, 1), band(dir, 1) == 1 and -SPILL_SPEED or SPILL_SPEED
                    put = put + Fill(nidx, nslot, g, share, t,
                        vx + (axis == 0 and sign or 0), vy + (axis == 1 and sign or 0), vz + (axis == 2 and sign or 0))
                end
            end
        end
    end
    return put
end

--- Разовый выброс (газомёт, API): amount концентрации поровну в ячейки шара радиуса r вокселей (0..3).
-- gasId = 0 — наоборот, очистка шара («пылесос»). Шар ≤ 7³ ячеек; вызывается событием, не в цикле ячеек.
local function Puff(gasId, x, y, z, amount, t, vx, vy, vz, r)
    local s = Spatial.VoxelSize
    local cgx, cgy, cgz = Spatial.WorldToGrid(x, y, z)
    local rr = (r + 0.5) * (r + 0.5)
    local n = 0
    for dz = -r, r do
        for dy = -r, r do
            for dx = -r, r do
                if dx * dx + dy * dy + dz * dz <= rr then n = n + 1 end
            end
        end
    end
    local per = gasId ~= 0 and amount / n or 0
    for dz = -r, r do
        local gz = cgz + dz
        for dy = -r, r do
            local gy = cgy + dy
            for dx = -r, r do
                local gx = cgx + dx
                if dx * dx + dy * dy + dz * dz <= rr and gx > 0 and gy > 0 and gz > 0
                    and gx < GRID_MASK and gy < GRID_MASK and gz < GRID_MASK then
                    if gasId == 0 then
                        local idx, slot = KeyIndex(bor(gx, lshift(gy, 10), lshift(gz, 20)), false)
                        if idx and Gas[idx] ~= 0 then ClearCell(idx, slot) end
                    else
                        InjectAt((gx - GRID_BIAS + 0.5) * s, (gy - GRID_BIAS + 0.5) * s, (gz - GRID_BIAS + 0.5) * s,
                            gasId, per, t, vx, vy, vz)
                    end
                end
            end
        end
    end
end

-- Выпуск воздуховода: центр и 4 точки поперёк струи (на расстоянии вокселя) — одна ячейка
-- не принимает больше MAX_CONC, поэтому поток раскладывается веером.
local DUCT_SPREAD = { { 0, 0 }, { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }
local function DuctOutput(src, out, dt)
    local give = src.buf < DUCT_OUT_RATE * dt and src.buf or DUCT_OUT_RATE * dt
    LocalVec:SetUnpacked(14, 0, 0)
    local op = out:LocalToWorld(LocalVec)
    local fw, rt, up = out:GetForward(), out:GetRight(), out:GetUp()
    local s = Spatial.VoxelSize
    local per = give / #DUCT_SPREAD
    local put = 0
    for i = 1, #DUCT_SPREAD do
        local o = DUCT_SPREAD[i]
        local ox, oy, oz = (rt.x * o[1] + up.x * o[2]) * s, (rt.y * o[1] + up.y * o[2]) * s, (rt.z * o[1] + up.z * o[2]) * s
        put = put + InjectAt(op.x + ox, op.y + oy, op.z + oz, src.bufGas, per, AMB,
            fw.x * DUCT_OUT_SPEED, fw.y * DUCT_OUT_SPEED, fw.z * DUCT_OUT_SPEED)
    end
    src.buf = src.buf - put
    if src.buf < 1e-4 then src.buf, src.bufGas = 0, 0 end
end

local function InjectSources(now, dt)
    for id, src in pairs(Sources) do
        local px, py, pz, vx, vy, vz = src.x, src.y, src.z, src.vx, src.vy, src.vz
        local alive = now < src.endTime
        local e
        if alive and src.ent > 0 then
            -- Источник на сущности: смещение и струя заданы в её локальных координатах.
            -- LocalToWorld выделяет Vector — O(число источников), не O(ячеек).
            e = Entity(src.ent)
            if IsValid(e) then
                LocalVec:SetUnpacked(src.x, src.y, src.z)
                local w = e:LocalToWorld(LocalVec)
                px, py, pz = w.x, w.y, w.z
                if vx ~= 0 or vy ~= 0 or vz ~= 0 then
                    LocalVec:SetUnpacked(vx, vy, vz)
                    local o, wv = e:GetPos(), e:LocalToWorld(LocalVec)
                    vx, vy, vz = wv.x - o.x, wv.y - o.y, wv.z - o.z
                end
            elseif SERVER then
                alive = false
            else
                px = nil   -- клиент: сущность вне PVS — пропускаем тик
            end
        end

        local kind = src.kind
        if not alive then
            Sources[id] = nil
        elseif not px then
            -- клиент: сущность вне PVS — пропускаем тик
        elseif kind == KIND_SINK then
            ApplySink(px, py, pz, src.radius, src.rate, dt)
        elseif kind == KIND_BLOW then
            -- Воздуходувка: струя вдоль «вперёд» сущности толкает газ, не уничтожая его
            if IsValid(e) then
                local fw = e:GetForward()
                Solver.PushRay(px, py, pz, px + fw.x * BLOW_LENGTH, py + fw.y * BLOW_LENGTH, pz + fw.z * BLOW_LENGTH,
                    src.radius, src.rate * dt, 0)
            end
        elseif kind == KIND_DUCT then
            -- Воздуховод: впуск забирает газ в трубу (не больше DUCT_HOLD), выпуск на другом конце отдаёт
            -- ту же массу того же газа. Пока труба полна, впуск не тянет — газ не теряется.
            local out = Entity(src.link)
            if IsValid(out) then
                if src.buf < DUCT_HOLD then
                    local _, g, amount = ApplySink(px, py, pz, src.radius, src.rate, dt)
                    if g ~= 0 and amount > 0 then
                        if src.bufGas ~= g and src.buf > 0 then amount = 0 end   -- в трубе другой газ: ждём
                        if amount > 0 then src.bufGas, src.buf = g, src.buf + amount end
                    end
                end
                if src.buf > 0 then DuctOutput(src, out, dt) end
            end
        else
            InjectAt(px, py, pz, src.gas, src.rate * dt, src.temp, vx, vy, vz)
        end
    end
end

--- gasId = 0 — сток (вытяжка) радиуса radius. ent > 0 — координаты и струя локальные для сущности.
-- duration <= 0 — бессрочно (до StopSource или удаления сущности).
-- kind: 0 выброс, 1 сток, 2 воздуходувка (rate — сила струи), 3 воздуховод (link — выпуск).
local function AddSourceLocal(id, gasId, x, y, z, rate, duration, temp, vx, vy, vz, ent, radius, kind, link)
    Sources[id] = {
        gas = gasId, x = x, y = y, z = z, rate = rate, temp = temp,
        vx = vx or 0, vy = vy or 0, vz = vz or 0,
        ent = ent or 0, radius = radius or 0,
        kind = kind or (gasId == 0 and KIND_SINK or KIND_EMIT), link = link or 0,
        buf = 0, bufGas = 0,   -- воздуховод: газ в трубе
        endTime = (duration and duration > 0) and (CurTime() + duration) or math.huge,
    }
end

---------------------------------------------------------------------------------------------------
-- Пули: 3D DDA (Amanatides–Woo) по сетке; газ на пути разрежается, затягивается диффузией
---------------------------------------------------------------------------------------------------
local MAX_DDA_STEPS = 512

local function Ignite(key)
    QueuePush(IgniteQ, key)
end
Solver.Ignite = Ignite

--- Возвращает ключ первой подожжённой ячейки (или nil).
local function Tunnel(x0, y0, z0, x1, y1, z1, igniteFlammable)
    if Pool.used == 0 then return nil end
    local firstIgnite
    local keep = 1 - CV.TunnelStrength:GetFloat()
    local inv = 1 / Spatial.VoxelSize
    local gx0, gy0, gz0 = x0 * inv + GRID_BIAS, y0 * inv + GRID_BIAS, z0 * inv + GRID_BIAS
    local dx, dy, dz = (x1 - x0) * inv, (y1 - y0) * inv, (z1 - z0) * inv
    local ix, iy, iz = floor(gx0), floor(gy0), floor(gz0)
    local ex, ey, ez = floor(gx0 + dx), floor(gy0 + dy), floor(gz0 + dz)

    local sx = dx > 0 and 1 or -1
    local sy = dy > 0 and 1 or -1
    local sz = dz > 0 and 1 or -1
    local tdx = dx ~= 0 and abs(1 / dx) or math.huge
    local tdy = dy ~= 0 and abs(1 / dy) or math.huge
    local tdz = dz ~= 0 and abs(1 / dz) or math.huge
    local tx = dx ~= 0 and ((dx > 0 and (ix + 1 - gx0) or (gx0 - ix)) * tdx) or math.huge
    local ty = dy ~= 0 and ((dy > 0 and (iy + 1 - gy0) or (gy0 - iy)) * tdy) or math.huge
    local tz = dz ~= 0 and ((dz > 0 and (iz + 1 - gz0) or (gz0 - iz)) * tdz) or math.huge

    for _ = 1, MAX_DDA_STEPS do
        if ix >= 0 and iy >= 0 and iz >= 0 and ix <= GRID_MASK and iy <= GRID_MASK and iz <= GRID_MASK then
            local key = bor(ix, lshift(iy, 10), lshift(iz, 20))
            local idx, slot = KeyIndex(key, false)
            if idx and Conc[idx] > 0 then
                local g = Gas[idx]
                local c = Conc[idx]
                if igniteFlammable and c >= PflameMin[g] and c <= PflameMax[g] then
                    Ignite(key)
                    firstIgnite = firstIgnite or key
                end
                if keep < 1 then
                    c = c * keep
                    if c < EPS then ClearCell(idx, slot) else Conc[idx] = c; slotDirty[slot] = true end
                end
            end
        end
        if ix == ex and iy == ey and iz == ez then break end
        if tx < ty and tx < tz then
            if tx > 1 then break end
            ix, tx = ix + sx, tx + tdx
        elseif ty < tz then
            if ty > 1 then break end
            iy, ty = iy + sy, ty + tdy
        else
            if tz > 1 then break end
            iz, tz = iz + sz, tz + tdz
        end
    end
    return firstIgnite
end
Solver.Tunnel = Tunnel

---------------------------------------------------------------------------------------------------
-- Взрыв: радиальный импульс ячейкам в сфере (+ поджиг горючего на сервере)
---------------------------------------------------------------------------------------------------
local function Blast(x, y, z, radius, strength, igniteFlammable)
    if Pool.used == 0 then return nil end
    local firstIgnite
    local s = Spatial.VoxelSize
    local r = math.ceil(radius / s)
    local cgx, cgy, cgz = Spatial.WorldToGrid(x, y, z)
    local r2 = radius * radius
    for gz = max(cgz - r, 1), min(cgz + r, GRID_MASK - 1) do
        local pz = (gz - GRID_BIAS + 0.5) * s - z
        for gy = max(cgy - r, 1), min(cgy + r, GRID_MASK - 1) do
            local py = (gy - GRID_BIAS + 0.5) * s - y
            for gx = max(cgx - r, 1), min(cgx + r, GRID_MASK - 1) do
                local px = (gx - GRID_BIAS + 0.5) * s - x
                local d2 = px * px + py * py + pz * pz
                if d2 <= r2 then
                    local key = bor(gx, lshift(gy, 10), lshift(gz, 20))
                    local idx, slot = KeyIndex(key, false)
                    if idx and Conc[idx] > 0 then
                        local d = sqrt(d2)
                        local push = strength * (1 - d / radius) / (d + 1)
                        VelX[idx] = VelX[idx] + px * push
                        VelY[idx] = VelY[idx] + py * push
                        VelZ[idx] = VelZ[idx] + pz * push
                        slotDirty[slot] = true
                        local g = Gas[idx]
                        if igniteFlammable and Conc[idx] >= PflameMin[g] and Conc[idx] <= PflameMax[g] then
                            Ignite(key)
                            firstIgnite = firstIgnite or key
                        end
                    end
                end
            end
        end
    end
    return firstIgnite
end
Solver.Blast = Blast

--- Струя вдоль луча (огнетушитель, вентиляторы других модов): ячейки в цилиндре радиуса radius вокруг
-- отрезка получают импульс вдоль него (strength·(1 − d/radius)) и теряют долю dilute концентрации.
function Solver.PushRay(x0, y0, z0, x1, y1, z1, radius, strength, dilute)
    if Pool.used == 0 then return end
    local s = Spatial.VoxelSize
    local dx, dy, dz = x1 - x0, y1 - y0, z1 - z0
    local len = sqrt(dx * dx + dy * dy + dz * dz)
    if len < 1 then return end
    dx, dy, dz = dx / len, dy / len, dz / len
    local r = math.ceil(radius / s)
    local steps = math.ceil(len / s)
    for i = 0, steps do
        local px, py, pz = x0 + dx * i * s, y0 + dy * i * s, z0 + dz * i * s
        local cgx, cgy, cgz = Spatial.WorldToGrid(px, py, pz)
        for gz = max(cgz - r, 1), min(cgz + r, GRID_MASK - 1) do
            for gy = max(cgy - r, 1), min(cgy + r, GRID_MASK - 1) do
                for gx = max(cgx - r, 1), min(cgx + r, GRID_MASK - 1) do
                    local idx, slot = KeyIndex(bor(gx, lshift(gy, 10), lshift(gz, 20)), false)
                    if idx and Conc[idx] > 0 then
                        local cx = (gx - GRID_BIAS + 0.5) * s - px
                        local cy = (gy - GRID_BIAS + 0.5) * s - py
                        local cz = (gz - GRID_BIAS + 0.5) * s - pz
                        local d = sqrt(cx * cx + cy * cy + cz * cz)
                        if d <= radius then
                            local w = 1 - d / radius
                            VelX[idx] = VelX[idx] + dx * strength * w
                            VelY[idx] = VelY[idx] + dy * strength * w
                            VelZ[idx] = VelZ[idx] + dz * strength * w
                            local c = Conc[idx] * (1 - dilute * w)
                            if c < EPS then ClearCell(idx, slot) else Conc[idx] = c; slotDirty[slot] = true end
                        end
                    end
                end
            end
        end
    end
end

---------------------------------------------------------------------------------------------------
-- Цепная детонация: по одному слою соседей за тик (фронт ≈ 66 вокселей/с)
---------------------------------------------------------------------------------------------------
local blastCalls, effectCalls = 0, 0
local DetPos = Vector(0, 0, 0)

local function Detonate(key, idx, slot, g, c)
    local x, y, z = Spatial.VoxelCenter(key)
    local s = Spatial.VoxelSize
    local energy = Pblast[g] * min(c, 1)

    -- Горение: газ сгорает, остаётся горячий едкий дым
    ClearCell(idx, slot)
    local coId = AetherGas.GetGasId("co_smoke")
    if coId > 0 then Fill(idx, slot, coId, c * 0.4, 650, 0, 0, 0) end

    -- Фронт в соседей через открытые грани + толчок наружу
    for dir = 0, 5 do
        if Spatial.FaceState(key, dir) == 1 then
            local nkey = key + DIR_STRIDE[dir]
            Ignite(nkey)
            local nidx, nslot = KeyIndex(nkey, false)
            if nidx and Conc[nidx] > 0 then
                local axis, sign = rshift(dir, 1), band(dir, 1) == 1 and -1 or 1
                if axis == 0 then VelX[nidx] = VelX[nidx] + sign * 300
                elseif axis == 1 then VelY[nidx] = VelY[nidx] + sign * 300
                else VelZ[nidx] = VelZ[nidx] + sign * 300 end
                slotDirty[nslot] = true
            end
        end
    end

    if CLIENT then return end
    DetPos:SetUnpacked(x, y, z)
    if blastCalls < MAX_BLASTDAMAGE_PER_TICK and energy > 0 then
        blastCalls = blastCalls + 1
        Solver.InDetonation = true
        util.BlastDamage(game.GetWorld(), game.GetWorld(), DetPos, s * 1.75, energy)
        Solver.InDetonation = false
    end
    if effectCalls < MAX_EFFECTS_PER_TICK then
        effectCalls = effectCalls + 1
        local ed = EffectData()
        ed:SetOrigin(DetPos)
        ed:SetMagnitude(1)
        ed:SetScale(1)
        util.Effect("Explosion", ed, true, true)
        local def = AetherGas.GasById[g]
        -- vFire: детонация разбрасывает живой огонь (как бочки JMod), он поджигает пропы и пол
        if def and def.igniteOnBlast and CreateVFireBall and CV.FireVFire:GetBool() then
            CreateVFireBall(math.random(8, 16), math.random(6, 12), DetPos, VectorRand() * math.random(80, 180))
        end
        if def and def.igniteOnBlast then
            local near = ents.FindInSphere(DetPos, s * 1.5)
            for i = 1, #near do
                local e = near[i]
                if IsValid(e) and (e:IsPlayer() or e:IsNPC() or e:GetMoveType() == MOVETYPE_VPHYSICS) then
                    e:Ignite(4)
                end
            end
        end
    end
end

local function ProcessIgnition()
    local pending = IgniteQ.count
    local done = 0
    while pending > 0 and done < MAX_DETONATIONS_PER_TICK do
        pending = pending - 1
        local key = QueuePop(IgniteQ)
        local idx, slot = KeyIndex(key, false)
        if idx and Gas[idx] ~= 0 then
            local g, c = Gas[idx], Conc[idx]
            if c >= PflameMin[g] then
                if c <= PflameMax[g] then
                    Detonate(key, idx, slot, g, c)
                    done = done + 1
                else
                    -- Слишком богатая смесь горит по краю: выгорает половина, ячейка ждёт снова
                    Conc[idx] = c * 0.5
                    slotDirty[slot] = true
                    QueuePush(IgniteQ, key)
                end
            end
        end
    end
end

---------------------------------------------------------------------------------------------------
-- Очистка
---------------------------------------------------------------------------------------------------
local function ClearAll()
    for slot = 1, Pool.highWater do
        local ck = slotKey[slot]
        if ck ~= -1 then Spatial.ReleaseChunk(ck) end
    end
    table.Empty(Sources)
    Spatial.QueueClear(IgniteQ)
end
Solver.ClearAll = ClearAll

hook.Add("AetherGas.GridRebuilt", "AetherGas.Solver", function()
    table.Empty(Outdoor)
    table.Empty(LastStep)
    table.Empty(EmptySince)
    Spatial.QueueClear(IgniteQ)
end)

---------------------------------------------------------------------------------------------------
-- Главный цикл: источники → поджиг → чанки по кругу в пределах бюджета
---------------------------------------------------------------------------------------------------
local cursor = 0
local cursorDir = 1   -- направление обхода слотов; меняется после каждого полного круга
local lastTick = CurTime()

hook.Add("Tick", "AetherGas.Solver.Step", function()
    local now = CurTime()
    local tickDt = now - lastTick
    lastTick = now
    if not CV.Enabled:GetBool() or tickDt <= 0 then return end
    if tickDt > MAX_DT then tickDt = MAX_DT end

    blastCalls, effectCalls = 0, 0
    Stats.cells = 0
    if next(Sources) ~= nil then InjectSources(now, tickDt) end
    if IgniteQ.count > 0 then ProcessIgnition() end

    local hw = Pool.highWater
    if Pool.used == 0 or hw == 0 then return end

    local t0 = SysTime()
    local deadline = t0 + CV.TickBudget:GetFloat() * 0.001
    local stepped = 0
    for _ = 1, hw do
        cursor = cursor + cursorDir
        if cursor > hw or cursor < 1 then
            cursorDir = -cursorDir
            cursor = cursorDir > 0 and 1 or hw
        end
        if slotKey[cursor] ~= -1 then
            local dt = now - (LastStep[cursor] or now)
            if dt >= MIN_DT then
                if dt > MAX_DT then dt = MAX_DT end
                LastStep[cursor] = now
                StepChunk(cursor, dt, now)
                stepped = stepped + 1
                if SysTime() > deadline then break end
            end
        end
    end
    Stats.chunks = stepped
    Stats.stepMs = (SysTime() - t0) * 1000
end)

---------------------------------------------------------------------------------------------------
-- Ветер: ConVar'ы или StormFox 2 (раз в секунду)
---------------------------------------------------------------------------------------------------
local UNITS_PER_METER = 52.49

timer.Create("AetherGas.Solver.Wind", 1, 0, function()
    local speed, yaw = CV.WindSpeed:GetFloat(), CV.WindYaw:GetFloat()
    local sf = StormFox2
    if CV.WindStormFox:GetBool() and sf and sf.Wind and sf.Wind.GetForce and sf.Wind.GetYaw then
        speed = (tonumber(sf.Wind.GetForce()) or 0) * UNITS_PER_METER
        yaw = tonumber(sf.Wind.GetYaw()) or yaw
    end
    local rad = math.rad(yaw)
    Solver.WindX, Solver.WindY = math.cos(rad) * speed, math.sin(rad) * speed
end)

---------------------------------------------------------------------------------------------------
-- Запросы к облаку (урон, эффекты, газоанализатор, слепота NPC)
---------------------------------------------------------------------------------------------------
--- Газ в точке: id, концентрация (обрезана до 1), температура. 0, 0, AMB — пусто.
function Solver.Sample(x, y, z)
    local key = Spatial.WorldToVoxel(x, y, z)
    if not key then return 0, 0, AMB end
    local idx = KeyIndex(key, false)
    if not idx or Gas[idx] == 0 then return 0, 0, AMB end
    local c = Conc[idx]
    return Gas[idx], c < 1 and c or 1, Temp[idx]
end

local PvisTh = P.VisionThreshold

--- Оптическая толщина вдоль отрезка: Σ по пройденным вокселям min(c,1)·opacity, только газы,
-- перекрывающие обзор (blocksVision) и выше их порога. Ранний выход при достижении limit.
function Solver.OpticalDepth(x0, y0, z0, x1, y1, z1, limit)
    if Pool.used == 0 then return 0 end
    limit = limit or math.huge
    local inv = 1 / Spatial.VoxelSize
    local gx0, gy0, gz0 = x0 * inv + GRID_BIAS, y0 * inv + GRID_BIAS, z0 * inv + GRID_BIAS
    local dx, dy, dz = (x1 - x0) * inv, (y1 - y0) * inv, (z1 - z0) * inv
    local ix, iy, iz = floor(gx0), floor(gy0), floor(gz0)
    local ex, ey, ez = floor(gx0 + dx), floor(gy0 + dy), floor(gz0 + dz)
    local sx, sy, sz = dx > 0 and 1 or -1, dy > 0 and 1 or -1, dz > 0 and 1 or -1
    local tdx = dx ~= 0 and abs(1 / dx) or math.huge
    local tdy = dy ~= 0 and abs(1 / dy) or math.huge
    local tdz = dz ~= 0 and abs(1 / dz) or math.huge
    local tx = dx ~= 0 and ((dx > 0 and (ix + 1 - gx0) or (gx0 - ix)) * tdx) or math.huge
    local ty = dy ~= 0 and ((dy > 0 and (iy + 1 - gy0) or (gy0 - iy)) * tdy) or math.huge
    local tz = dz ~= 0 and ((dz > 0 and (iz + 1 - gz0) or (gz0 - iz)) * tdz) or math.huge
    local depth = 0
    for _ = 1, MAX_DDA_STEPS do
        if ix >= 0 and iy >= 0 and iz >= 0 and ix <= GRID_MASK and iy <= GRID_MASK and iz <= GRID_MASK then
            local idx = KeyIndex(bor(ix, lshift(iy, 10), lshift(iz, 20)), false)
            if idx then
                local g, c = Gas[idx], Conc[idx]
                if g ~= 0 and c >= PvisTh[g] then
                    depth = depth + (c < 1 and c or 1) * P.Opacity[g]
                    if depth >= limit then return depth end
                end
            end
        end
        if ix == ex and iy == ey and iz == ez then break end
        if tx < ty and tx < tz then
            if tx > 1 then break end
            ix, tx = ix + sx, tx + tdx
        elseif ty < tz then
            if ty > 1 then break end
            iy, ty = iy + sy, ty + tdy
        else
            if tz > 1 then break end
            iz, tz = iz + sz, tz + tdz
        end
    end
    return depth
end

--- Снимок чанка для синхронизации: 512 × (id газа, концентрация в 8 бит), сжатый util.Compress.
-- Сетевой путь (раз в секунды на чанк), аллокации здесь допустимы.
local CONC_Q = 255 / MAX_CONC
function Solver.EncodeChunk(slot)
    local base = lshift(slot - 1, 9)
    local bytes = {}
    for li = 1, 512 do
        local i = base + li
        bytes[li * 2 - 1] = Gas[i]
        bytes[li * 2] = min(255, floor(Conc[i] * CONC_Q + 0.5))
    end
    local parts = {}
    for p = 0, 3 do parts[p + 1] = string.char(unpack(bytes, p * 256 + 1, p * 256 + 256)) end
    return util.Compress(table.concat(parts))
end

--- Применяет снимок к чанку (перезаписывает газ и концентрацию; температура сохраняется у того же газа).
function Solver.ApplyChunk(chunkKey, data)
    local raw = util.Decompress(data)
    if not raw or #raw ~= 1024 then return end
    local slot = SlotFor(chunkKey, true)
    if not slot then return end
    local base = lshift(slot - 1, 9)
    local count = 0
    for li = 1, 512 do
        local i = base + li
        local g, q = string.byte(raw, li * 2 - 1, li * 2)
        if g == 0 or q == 0 or not AetherGas.GasById[g] then
            Gas[i], Conc[i], Temp[i] = 0, 0, AMB
            VelX[i], VelY[i], VelZ[i] = 0, 0, 0
        else
            if Gas[i] ~= g then Temp[i] = P.EmitTemp[g] end
            Gas[i], Conc[i] = g, q / CONC_Q
            count = count + 1
        end
    end
    slotCount[slot] = count
    slotDirty[slot] = true
    EmptySince[slot] = nil
end

-- Замедление в газе: сервер выставляет NW2-float, обе стороны применяют в SetupMove (без рывков предсказания).
hook.Add("SetupMove", "AetherGas.Solver.Slow", function(ply, mv)
    local s = ply:GetNW2Float("AetherSlow", 0)
    if ply:GetNW2Bool("AetherSuit", false) then s = 1 - (1 - s) * 0.9 end   -- костюм химзащиты: −10 %
    if s > 0.001 then
        local f = 1 - s
        mv:SetMaxClientSpeed(mv:GetMaxClientSpeed() * f)
        mv:SetMaxSpeed(mv:GetMaxSpeed() * f)
    end
end)

---------------------------------------------------------------------------------------------------
-- Сеть
---------------------------------------------------------------------------------------------------
local function ReadEvent()
    local kind = net.ReadUInt(3)
    if kind == EV_SOURCE then
        local id, gasId = net.ReadUInt(16), net.ReadUInt(8)
        local pos = net.ReadVector()
        local rate, duration, temp = net.ReadFloat(), net.ReadFloat(), net.ReadFloat()
        local vel = net.ReadVector()
        local ent, radius = net.ReadUInt(13), net.ReadUInt(12)
        local skind, link = net.ReadUInt(2), net.ReadUInt(13)
        AddSourceLocal(id, gasId, pos.x, pos.y, pos.z, rate, duration, temp, vel.x, vel.y, vel.z, ent, radius, skind, link)
    elseif kind == EV_STOP then
        Sources[net.ReadUInt(16)] = nil
    elseif kind == EV_TUNNEL then
        local a, b = net.ReadVector(), net.ReadVector()
        Tunnel(a.x, a.y, a.z, b.x, b.y, b.z, false)
    elseif kind == EV_BLAST then
        local pos = net.ReadVector()
        local radius, strength = net.ReadUInt(12), net.ReadFloat()
        Blast(pos.x, pos.y, pos.z, radius, strength, false)
    elseif kind == EV_IGNITE then
        Ignite(net.ReadUInt(30))
    elseif kind == EV_CLEAR then
        ClearAll()
    elseif kind == EV_PUSH then
        local a, b = net.ReadVector(), net.ReadVector()
        local radius, strength, dilute = net.ReadUInt(10), net.ReadFloat(), net.ReadFloat()
        Solver.PushRay(a.x, a.y, a.z, b.x, b.y, b.z, radius, strength, dilute)
    elseif kind == EV_PUFF then
        local gasId, pos = net.ReadUInt(8), net.ReadVector()
        local amount, temp, vel, r = net.ReadFloat(), net.ReadFloat(), net.ReadVector(), net.ReadUInt(2)
        Puff(gasId, pos.x, pos.y, pos.z, amount, temp, vel.x, vel.y, vel.z, r)
    end
end

if CLIENT then
    net.Receive(C.NET_SOLVER, function()
        local n = net.ReadUInt(8)
        for _ = 1, n do ReadEvent() end
    end)
    -- Снимки чанков от сервера: исправляют накопленное расхождение и догоняют поздно вошедших.
    net.Receive(C.NET_SNAPSHOT, function()
        local n = net.ReadUInt(8)
        for _ = 1, n do
            local ck = net.ReadUInt(21)
            local len = net.ReadUInt(16)
            Solver.ApplyChunk(ck, net.ReadData(len))
        end
    end)
    return
end

---------------------------------------------------------------------------------------------------
-- Сервер: публичный API + детекторы пуль, взрывов, огня
---------------------------------------------------------------------------------------------------
local function WriteSource(id, src, now)
    net.WriteUInt(EV_SOURCE, 3)
    net.WriteUInt(id, 16)
    net.WriteUInt(src.gas, 8)
    net.WriteVector(Vector(src.x, src.y, src.z))
    net.WriteFloat(src.rate)
    net.WriteFloat(src.endTime == math.huge and -1 or math.max(src.endTime - now, 0.01))
    net.WriteFloat(src.temp)
    net.WriteVector(Vector(src.vx, src.vy, src.vz))
    net.WriteUInt(src.ent, 13)
    net.WriteUInt(math.min(floor(src.radius), 4095), 12)
    net.WriteUInt(src.kind, 2)
    net.WriteUInt(src.link, 13)
end

local function NewSourceId()
    local id = Solver.NextSourceId
    Solver.NextSourceId = id % 65535 + 1
    return id
end

local function BroadcastSource(id)
    net.Start(C.NET_SOLVER)
    net.WriteUInt(1, 8)
    WriteSource(id, Sources[id], CurTime())
    net.Broadcast()
end

--- Создаёт источник газа. gas — имя или id; pos — Vector (мировой или локальный при ent);
-- rate — концентрация/с в ячейку источника; duration — с (<= 0 — бессрочно);
-- temp — °C (по умолчанию emitTemp газа); vel — Vector струи (опционально);
-- ent — сущность-носитель (pos и vel тогда в её локальных координатах).
-- Возвращает id источника (для Solver.StopSource) или nil.
function Solver.AddSource(gas, pos, rate, duration, temp, vel, ent)
    local def = AetherGas.GetGas(gas)
    if not def then return nil end
    local id = NewSourceId()
    AddSourceLocal(id, def.id, pos.x, pos.y, pos.z, rate, duration, temp or def.emitTemp,
        vel and vel.x or 0, vel and vel.y or 0, vel and vel.z or 0, IsValid(ent) and ent:EntIndex() or 0, 0)
    BroadcastSource(id)
    return id
end

--- Сток (вытяжка): убирает rate концентрации/с в шаре radius вокруг pos (локально к ent, если задан).
--- Воздуходувка: на сущности ent, струя длиной 420 вдоль её «вперёд» из точки pos (локально).
function Solver.AddBlower(ent, pos, strength, radius)
    local id = NewSourceId()
    AddSourceLocal(id, 0, pos.x, pos.y, pos.z, strength, 0, AMB, 0, 0, 0, ent:EntIndex(), math.Clamp(radius, 16, 1000), KIND_BLOW, 0)
    BroadcastSource(id)
    return id
end

--- Воздуховод: впуск inEnt (зона radius вокруг pos, локально) → выпуск outEnt (10 юнитов перед ним).
function Solver.AddDuct(inEnt, outEnt, pos, rate, radius)
    local id = NewSourceId()
    AddSourceLocal(id, 0, pos.x, pos.y, pos.z, rate, 0, AMB, 0, 0, 0, inEnt:EntIndex(), math.Clamp(radius, 16, 1000), KIND_DUCT, outEnt:EntIndex())
    BroadcastSource(id)
    return id
end

function Solver.AddSink(pos, radius, rate, duration, ent)
    local id = NewSourceId()
    AddSourceLocal(id, 0, pos.x, pos.y, pos.z, rate, duration, AMB, 0, 0, 0,
        IsValid(ent) and ent:EntIndex() or 0, math.Clamp(radius, 16, 4000))
    BroadcastSource(id)
    return id
end

function Solver.StopSource(id)
    if not Sources[id] then return end
    Sources[id] = nil
    net.Start(C.NET_SOLVER)
    net.WriteUInt(1, 8)
    net.WriteUInt(EV_STOP, 3)
    net.WriteUInt(id, 16)
    net.Broadcast()
end

local function BroadcastIgnite(key)
    Ignite(key)
    net.Start(C.NET_SOLVER)
    net.WriteUInt(1, 8)
    net.WriteUInt(EV_IGNITE, 3)
    net.WriteUInt(key, 30)
    net.Broadcast()
end
Solver.BroadcastIgnite = BroadcastIgnite

-- Пакет выбросов: между BeginPuffBatch и EndPuffBatch события PuffAt копятся в плоских массивах
-- и уходят одним-двумя net-сообщениями (дым от десятков очагов пожара за один проход).
local PB = { on = false, n = 0, id = {}, x = {}, y = {}, z = {}, amt = {}, t = {}, vx = {}, vy = {}, vz = {}, r = {} }
local PB_MAX = 200   -- событий в одном сообщении: 200 × ~34 байта ≈ 7 КБ < 64 КБ

function Solver.BeginPuffBatch()
    PB.on, PB.n = true, 0
end

local PuffVec, PuffVel = Vector(0, 0, 0), Vector(0, 0, 0)
function Solver.EndPuffBatch()
    PB.on = false
    local i = 1
    while i <= PB.n do
        local last = min(i + PB_MAX - 1, PB.n)
        net.Start(C.NET_SOLVER)
        net.WriteUInt(last - i + 1, 8)
        for k = i, last do
            net.WriteUInt(EV_PUFF, 3)
            net.WriteUInt(PB.id[k], 8)
            PuffVec:SetUnpacked(PB.x[k], PB.y[k], PB.z[k])
            net.WriteVector(PuffVec)
            net.WriteFloat(PB.amt[k])
            net.WriteFloat(PB.t[k])
            PuffVel:SetUnpacked(PB.vx[k], PB.vy[k], PB.vz[k])
            net.WriteVector(PuffVel)
            net.WriteUInt(PB.r[k], 2)
        end
        net.Broadcast()
        i = last + 1
    end
    PB.n = 0
end

--- Струя вдоль луча с репликацией (см. Solver.PushRay).
function Solver.PushRayAt(a, b, radius, strength, dilute)
    if Pool.used == 0 then return end
    radius = math.Clamp(radius, 16, 1000)
    Solver.PushRay(a.x, a.y, a.z, b.x, b.y, b.z, radius, strength, dilute)
    net.Start(C.NET_SOLVER)
    net.WriteUInt(1, 8)
    net.WriteUInt(EV_PUSH, 3)
    net.WriteVector(a)
    net.WriteVector(b)
    net.WriteUInt(floor(radius), 10)
    net.WriteFloat(strength)
    net.WriteFloat(dilute)
    net.Broadcast()
end

--- Разовый выброс с репликацией. gas — имя/id (nil или 0 — очистка шара); amount — концентрации всего;
-- temp — °C (nil — emitTemp газа); vel — Vector струи (nil — без); r — радиус шара в вокселях 0..3.
function Solver.PuffAt(gas, pos, amount, temp, vel, r)
    local id = 0
    if gas ~= nil and gas ~= 0 then
        local def = AetherGas.GetGas(gas)
        if not def then return end
        id = def.id
        temp = temp or def.emitTemp
    end
    r = math.Clamp(floor(r or 0), 0, 3)
    amount = math.Clamp(tonumber(amount) or 0, 0, 200)
    temp = temp or AMB
    vel = vel or vector_origin
    Puff(id, pos.x, pos.y, pos.z, amount, temp, vel.x, vel.y, vel.z, r)
    if PB.on then
        local n = PB.n + 1
        PB.n = n
        PB.id[n], PB.x[n], PB.y[n], PB.z[n], PB.amt[n], PB.t[n] = id, pos.x, pos.y, pos.z, amount, temp
        PB.vx[n], PB.vy[n], PB.vz[n], PB.r[n] = vel.x, vel.y, vel.z, r
        return
    end
    net.Start(C.NET_SOLVER)
    net.WriteUInt(1, 8)
    net.WriteUInt(EV_PUFF, 3)
    net.WriteUInt(id, 8)
    net.WriteVector(pos)
    net.WriteFloat(amount)
    net.WriteFloat(temp)
    net.WriteVector(vel)
    net.WriteUInt(r, 2)
    net.Broadcast()
end

--- Взрывной импульс. noIgnite = true — только толчок (поток от винта, ударная волна без огня).
function Solver.BlastAt(pos, radius, strength, noIgnite)
    if Pool.used == 0 then return end
    radius = math.Clamp(radius, 32, 4000)
    -- Поджиг на сервере идёт отдельным событием: клиенты получают импульс и точку поджига
    local igniteKey = Blast(pos.x, pos.y, pos.z, radius, strength, not noIgnite)
    net.Start(C.NET_SOLVER)
    net.WriteUInt(1, 8)
    net.WriteUInt(EV_BLAST, 3)
    net.WriteVector(pos)
    net.WriteUInt(floor(radius), 12)
    net.WriteFloat(strength)
    net.Broadcast()
    if igniteKey then BroadcastIgnite(igniteKey) end
end

function Solver.Clear()
    ClearAll()
    net.Start(C.NET_SOLVER)
    net.WriteUInt(1, 8)
    net.WriteUInt(EV_CLEAR, 3)
    net.Broadcast()
end

-- Новый игрок получает активные источники (облака он досчитает сам; точная синхронизация — sv_network)
hook.Add("AetherGas.ClientReady", "AetherGas.Solver", function(ply)
    local now = CurTime()
    local ids = {}
    for id in pairs(Sources) do ids[#ids + 1] = id end
    local first = 1
    while first <= #ids do
        local last = min(first + 15, #ids)
        net.Start(C.NET_SOLVER)
        net.WriteUInt(last - first + 1, 8)
        for i = first, last do WriteSource(ids[i], Sources[ids[i]], now) end
        net.Send(ply)
        first = last + 1
    end
end)

-- Пули: туннель видимости в дыму. Только чтение data; ничего не возвращаем.
-- Поджиг горючего газа пулей — только там, где есть искра или пламя:
--   • дульное пламя: точка выстрела (data.Src) внутри горючей смеси;
--   • искра попадания: пуля бьёт в металл/решётку/технику (всегда) или бетон/плитку (с шансом) внутри смеси;
--   • энергетический заряд (трассер AR2) — искра при любом попадании.
-- Пролёт пули сквозь облако сам по себе газ не поджигает (раньше поджигалась вся траектория).
local SPARK_ALWAYS = { [MAT_METAL] = true, [MAT_GRATE] = true, [MAT_VENT] = true, [MAT_COMPUTER] = true }
local SPARK_SOMETIMES = { [MAT_CONCRETE] = 0.35, [MAT_TILE] = 0.35, [MAT_GLASS] = 0.2 }
local NO_SPARK = { [MAT_FLESH] = true, [MAT_ALIENFLESH] = true, [MAT_BLOODYFLESH] = true }

--- Ключ ячейки с горючей смесью в пределах воспламенения в точке (x, y, z) или nil.
local function FlammableAt(x, y, z)
    local key = Spatial.WorldToVoxel(x, y, z)
    if not key then return nil end
    local idx = KeyIndex(key, false)
    if not idx then return nil end
    local g, c = Gas[idx], Conc[idx]
    if g ~= 0 and c >= PflameMin[g] and c <= PflameMax[g] then return key end
    return nil
end
Solver.FlammableAt = FlammableAt

local tunnelsThisTick, tunnelTick = 0, 0
hook.Add("PostEntityFireBullets", "AetherGas.Solver.Bullets", function(_, data)
    if Pool.used == 0 then return end
    local tr = data and data.Trace
    if not tr then return end
    local t = engine.TickCount()
    if t ~= tunnelTick then tunnelTick, tunnelsThisTick = t, 0 end
    if tunnelsThisTick >= MAX_TUNNELS_PER_TICK then return end
    tunnelsThisTick = tunnelsThisTick + 1

    local a, b = tr.StartPos, tr.HitPos
    Tunnel(a.x, a.y, a.z, b.x, b.y, b.z, false)
    net.Start(C.NET_SOLVER)
    net.WriteUInt(1, 8)
    net.WriteUInt(EV_TUNNEL, 3)
    net.WriteVector(a)
    net.WriteVector(b)
    net.Broadcast()

    if Solver.FlammableSeen and CurTime() - Solver.FlammableSeen > 2 then return end   -- горючего нигде нет
    -- дульное пламя
    local src = data.Src or a
    local key = FlammableAt(src.x, src.y, src.z)
    -- искра в точке попадания (чуть перед поверхностью — в ячейке с газом, а не в стене)
    if not key and tr.Hit and not tr.HitSky then
        local mat = tr.MatType
        local energy = data.TracerName == "AR2Tracer"
        local chance = (energy or SPARK_ALWAYS[mat]) and 1 or (SPARK_SOMETIMES[mat] or 0)
        if not NO_SPARK[mat] and chance > 0 and math.random() < chance then
            local n = tr.HitNormal
            key = FlammableAt(b.x + n.x * 4, b.y + n.y * 4, b.z + n.z * 4)
        end
    end
    if key then BroadcastIgnite(key) end
end)

-- Взрывы: GMod не даёт хука «взрыв», ловим урон DMG_BLAST и склеиваем одну детонацию по месту/времени.
local lastBlastT, lastBlastPos = 0, Vector(0, 0, 0)
hook.Add("EntityTakeDamage", "AetherGas.Solver.Blast", function(_, dmg)
    if Solver.InDetonation or Pool.used == 0 or not dmg:IsExplosionDamage() then return end
    local pos = dmg:GetReportedPosition()
    if pos:IsZero() then pos = dmg:GetDamagePosition() end
    local now = CurTime()
    if now - lastBlastT < 0.15 and pos:DistToSqr(lastBlastPos) < 96 * 96 then return end
    lastBlastT = now
    lastBlastPos:Set(pos)
    Solver.BlastAt(pos, math.Clamp(dmg:GetDamage() * 2.5, 128, 600), 900)
end)

-- Огонь (поджиг газа, дым пожаров, тушение инертным газом, vFire) — в sh_fire.lua.

---------------------------------------------------------------------------------------------------
-- Тестовые команды (суперадмин / одиночная игра)
---------------------------------------------------------------------------------------------------
local function CanCmd(ply)
    return not IsValid(ply) or game.SinglePlayer() or ply:IsSuperAdmin()
end

concommand.Add("aether_spawn", function(ply, _, args)
    if not CanCmd(ply) or not IsValid(ply) then return end
    local def = AetherGas.GetGas(args[1] or "smoke")
    if not def then
        ply:PrintMessage(HUD_PRINTCONSOLE, "[Aether] gases: " .. table.concat(AetherGas.BaseGases, ", ") .. "\n")
        return
    end
    local rate = math.Clamp(tonumber(args[2]) or 6, 0.1, 40)
    local duration = math.Clamp(tonumber(args[3]) or 12, 0.5, 600)
    local tr = ply:GetEyeTrace()
    local pos = tr.HitPos + tr.HitNormal * (Spatial.VoxelSize * 0.5)
    local id = Solver.AddSource(def.name, pos, rate, duration)
    ply:PrintMessage(HUD_PRINTCONSOLE, string.format("[Aether] source #%d: %s, %.1f/s, %.0f s\n", id, def.name, rate, duration))
end, nil, "Aether: gas source at aim. Arguments: [gas=smoke] [rate=6] [duration=12]")

concommand.Add("aether_clear", function(ply)
    if not CanCmd(ply) then return end
    Solver.Clear()
end, nil, "Aether: remove all gas and sources")

concommand.Add("aether_ignite", function(ply)
    if not CanCmd(ply) or not IsValid(ply) then return end
    local tr = ply:GetEyeTrace()
    local p = tr.HitPos + tr.HitNormal * (Spatial.VoxelSize * 0.5)
    local key = Spatial.WorldToVoxel(p.x, p.y, p.z)
    if key then BroadcastIgnite(key) end
end, nil, "Aether: ignite gas at aim")
