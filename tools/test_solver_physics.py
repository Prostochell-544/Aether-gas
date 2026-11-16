"""Порт StepCell из sh_solver.lua (без чанков/сети) — проверка физики в закрытой комнате.
Комната 12×12×6 вокселей, стены вокруг, источник в центре на высоте 2.
Проверяется: масса сохраняется (decay=0), нет отрицательных/NaN, хлор оседает, метан всплывает,
дым заполняет объём, горячий co_smoke поднимается к потолку."""
import math

MAX_CONC, EPS, OVERWRITE, MAX_K, FLOW_CAP, BUOY_RATE, VEL_DAMP = 2.0, 0.003, 0.02, 0.15, 0.45, 1.2, 2.5
AMB, KELVIN = 20.0, 273.15
AMB_K = AMB + KELVIN
GASES = {  # density, diffusion, spread, emitTemp, cooling, cohesion
    "smoke": (1.0, 0.22, 0.85, 30, 0.25, 0.45),
    "chlorine": (1.8, 0.10, 0.35, 15, 0.1, 0.05),
    "methane": (0.55, 0.20, 0.5, 20, 0.05, 0.0),
    "co_smoke": (0.95, 0.16, 0.55, 320, 0.035, 0.1),
}
NX, NY, NZ = 12, 12, 6
DIRS = [(1, 0, 0), (-1, 0, 0), (0, 1, 0), (0, -1, 0), (0, 0, 1), (0, 0, -1)]


def run(gas, seconds=20.0, dt=0.1, rate=6.0, src_time=5.0):
    dens, diff, spread, emitT, cool, coh = GASES[gas]
    conc = {(x, y, z): 0.0 for x in range(NX) for y in range(NY) for z in range(NZ)}
    temp = {k: AMB for k in conc}
    injected = 0.0
    t, forward = 0.0, True
    order = sorted(conc)
    while t < seconds:
        if t < src_time:  # источник
            k = (NX // 2, NY // 2, 2)
            add = min(rate * dt, MAX_CONC - conc[k])
            w = add / (conc[k] + add) if conc[k] + add > 0 else 0
            temp[k] += (emitT - temp[k]) * w
            conc[k] += add
            injected += add
        seq = order if forward else order[::-1]
        forward = not forward
        for key in seq:
            c = conc[key]
            if c <= 0:
                continue
            T = temp[key]
            buoy = 1 - dens * AMB_K / max(T + KELVIN, 50)
            k = min((diff + spread * min(c, 1)) * dt, MAX_K)
            up = min(max(1 + 2 * buoy, 0), 1)
            down = min(max(1 - 2 * buoy, 0), 1)
            drift = BUOY_RATE * dt * c
            rem = c
            for d, (dx, dy, dz) in enumerate(DIRS):
                n = (key[0] + dx, key[1] + dy, key[2] + dz)
                if n not in conc:
                    continue  # стена
                cn = conc[n]
                base = cn if cn > coh else coh
                flow = k * (c - base) if c > base else 0
                if dz == 1:
                    flow *= up
                    if buoy > 0: flow += drift * buoy
                elif dz == -1:
                    flow *= down
                    if buoy < 0: flow -= drift * buoy
                flow = min(flow, rem * FLOW_CAP)
                if flow > 1e-5:
                    room = MAX_CONC - cn
                    flow = min(flow, room)
                    if flow <= 0: continue
                    w = flow / (cn + flow)
                    temp[n] += (T - temp[n]) * w
                    conc[n] = cn + flow
                    rem -= flow
            conc[key] = rem
            temp[key] = T + (AMB - T) * min(1, cool * dt)
        t += dt
    vals = list(conc.values())
    mass = sum(vals)
    assert all(v >= 0 and not math.isnan(v) for v in vals), "отрицательная/NaN концентрация"
    assert abs(mass - injected) < 1e-6 * max(1, injected), f"масса не сохранилась: {mass} vs {injected}"
    zc = sum(v * z for (x, y, z), v in conc.items()) / mass
    filled = sum(v for v in vals if v > 0.3) / mass  # доля массы в плотных ячейках
    print(f"{gas:9} масса {mass:7.3f}=впрыск {injected:7.3f}  центр масс z={zc:4.2f} (0 пол, 5 потолок)  "
          f"в плотных ячейках {filled * 100:5.1f}% массы  макс {max(vals):.2f}")
    return zc, filled


z_smoke, f_smoke = run("smoke")
z_cl, _ = run("chlorine")
z_me, _ = run("methane")
z_co, _ = run("co_smoke", seconds=6.0)
assert z_cl < 1.0, "хлор должен лечь на пол"
assert z_me > 3.5, "метан должен подняться к потолку"
assert z_co > 2.5, "горячий дым пожара должен уйти вверх"
assert f_smoke > 0.8, "дым должен держать плотный объём, а не размазываться"
print("SOLVER PHYSICS OK")
