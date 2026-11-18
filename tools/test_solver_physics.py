"""Порт StepCell + InjectAt из sh_solver.lua (без чанков/сети) — проверка физики.

Сценарии:
  • закрытая комната 12×12×6, источник в центре на высоте 2: масса сохраняется (decay = 0, перелив у
    источника), нет отрицательных/NaN, хлор оседает, метан всплывает, горячий co_smoke уходит вверх,
    дым держит плотный объём, а за 4 минуты расплывается дымкой (утечка когезии);
  • две комнаты с дверью (проём 1×2 в стене): мощный источник выдавливает газ в соседнюю комнату
    (избыточное давление + разгон), масса сохраняется.
Обновлять вместе со StepCell / InjectAt.
"""
import math

MAX_CONC, EPS, OVERWRITE, MAX_K, FLOW_CAP, BUOY_RATE, VEL_DAMP = 3.0, 0.003, 0.02, 0.15, 0.45, 1.2, 2.5
OFFGAS_RATE = 0.012
DEPOSIT = {"chlorine": 0.004}   # доля/с, оседающая на пол (sh_registry deposit)
COH_LEAK, PRESS_RATE, PRESS_ACCEL, SPILL_SPEED = 0.008, 1.6, 260.0, 120.0
S = 40.0  # размер вокселя
AMB, KELVIN = 20.0, 273.15
AMB_K = AMB + KELVIN
GASES = {  # density, diffusion, spread, emitTemp, cooling, cohesion
    "smoke": (1.0, 0.22, 0.85, 30, 0.25, 0.45),
    "chlorine": (1.8, 0.10, 0.35, 15, 0.1, 0.05),
    "methane": (0.55, 0.20, 0.5, 20, 0.05, 0.0),
    "co_smoke": (0.95, 0.16, 0.55, 320, 0.035, 0.1),
}
DIRS = [(1, 0, 0), (-1, 0, 0), (0, 1, 0), (0, -1, 0), (0, 0, 1), (0, 0, -1)]


class World:
    def __init__(self, cells):
        self.c = {k: 0.0 for k in cells}
        self.t = {k: AMB for k in cells}
        self.v = {k: [0.0, 0.0, 0.0] for k in cells}
        self.order = sorted(cells)
        self.dep = {k: 0.0 for k in cells}

    def fill(self, k, amount, temp, vel):
        cur = self.c[k]
        amount = min(amount, MAX_CONC - cur)
        if amount <= 0:
            return 0.0
        w = amount / (cur + amount)
        self.t[k] += (temp - self.t[k]) * w
        for a in range(3):
            self.v[k][a] += (vel[a] - self.v[k][a]) * w
        self.c[k] = cur + amount
        return amount

    def inject(self, k, amount, temp):
        put = self.fill(k, amount, temp, (0, 0, 0))
        rest = amount - put
        if rest < 1e-4:
            return put
        nb = [(d, (k[0] + d[0], k[1] + d[1], k[2] + d[2])) for d in DIRS]
        nb = [(d, n) for d, n in nb if n in self.c]
        for d, n in nb:  # перелив излишка в соседей с толчком наружу
            put += self.fill(n, rest / len(nb), temp, tuple(SPILL_SPEED * x for x in d))
        return put

    def step(self, gas, dt, forward):
        dens, diff, spread, emitT, cool, coh = GASES[gas]
        dr = DEPOSIT.get(gas, 0.0)
        for key in (self.order if forward else self.order[::-1]):
            d0 = self.dep[key]
            if d0 > 0:   # испарение осадка обратно в ячейку
                amt = d0 if d0 < 0.004 else d0 * OFFGAS_RATE * dt
                put = self.fill(key, amt, AMB, (0, 0, 0))
                if put > 0 or d0 < 0.004:
                    self.dep[key] = d0 - (d0 if d0 < 0.004 else put)
            c = self.c[key]
            if c <= 0:
                continue
            T = self.t[key]
            buoy = 1 - dens * AMB_K / max(T + KELVIN, 50)
            k = min((diff + spread * min(c, 1)) * dt, MAX_K)
            up = min(max(1 + 2 * buoy, 0), 1)
            down = min(max(1 - 2 * buoy, 0), 1)
            drift = BUOY_RATE * dt * c
            adv = dt / S * c
            ex = c - 1 if c > 1 else 0
            acc = [0.0, 0.0, 0.0]
            vel = self.v[key]
            rem = c
            for d in DIRS:
                n = (key[0] + d[0], key[1] + d[1], key[2] + d[2])
                if n not in self.c:
                    continue  # стена
                cn = self.c[n]
                axis = 0 if d[0] else (1 if d[1] else 2)
                sign = d[axis]
                dp = ex - (cn - 1 if cn > 1 else 0)
                if dp > 0:
                    acc[axis] += sign * PRESS_ACCEL * dt * dp
                floor_c = cn if cn > coh else coh
                flow = k * (c - floor_c) if c > floor_c else 0.0
                if c > cn:
                    flow += COH_LEAK * dt * (c - cn)
                if axis == 2 and sign == 1:
                    flow *= up
                    if buoy > 0: flow += drift * buoy
                elif axis == 2:
                    flow *= down
                    if buoy < 0: flow -= drift * buoy
                if dp > 0:
                    flow += min(PRESS_RATE * dt * dp, 0.4 * dp)
                vv = vel[axis] * sign
                if vv > 0:
                    flow += vv * adv
                flow = min(flow, rem * FLOW_CAP)
                if flow > 1e-5:
                    rem -= self.fill(n, flow, T, vel)
            below = (key[0], key[1], key[2] - 1)
            if dr > 0 and below not in self.c:   # под ячейкой пол — оседание
                d = rem * dr * dt
                rem -= d
                self.dep[key] += d
            self.c[key] = rem
            self.t[key] = T + (AMB - T) * min(1, cool * dt)
            damp = max(0.0, 1 - VEL_DAMP * dt)
            self.v[key] = [(vel[a] + acc[a]) * damp for a in range(3)]

    def check(self, injected):
        vals = list(self.c.values())
        mass = sum(vals) + sum(self.dep.values())
        assert all(v >= 0 and not math.isnan(v) for v in vals), "отрицательная/NaN концентрация"
        assert all(not math.isnan(x) for v in self.v.values() for x in v), "NaN в скорости"
        assert abs(mass - injected) < 1e-6 * max(1, injected), f"масса не сохранилась: {mass} vs {injected}"
        return mass


def run_room(gas, seconds=20.0, dt=0.1, rate=6.0, src_time=5.0):
    NX, NY, NZ = 12, 12, 6
    w = World([(x, y, z) for x in range(NX) for y in range(NY) for z in range(NZ)])
    src = (NX // 2, NY // 2, 2)
    injected, t, forward = 0.0, 0.0, True
    while t < seconds:
        if t < src_time:
            injected += w.inject(src, rate * dt, GASES[gas][3])
        w.step(gas, dt, forward)
        forward = not forward
        t += dt
    mass = w.check(injected)
    vals = list(w.c.values())
    zc = sum(v * z for (x, y, z), v in w.c.items()) / mass
    filled = sum(v for v in vals if v > 0.3) / mass        # доля массы в плотных ячейках
    haze = sum(1 for v in vals if v > 0.02) / len(vals)     # доля объёма, где газ вообще есть
    print(f"{gas:9} {seconds:5.0f}s масса {mass:7.3f}=впрыск {injected:7.3f}  центр z={zc:4.2f}  "
          f"плотные {filled * 100:5.1f}%  объём с газом {haze * 100:5.1f}%  макс {max(vals):.2f}")
    return zc, filled, haze


def run_door(seconds=12.0, dt=0.1, rate=30.0):
    """Две комнаты 8×8×4 (x 0..7 и 9..16), стена x = 8 с проёмом 1×2 (y = 4, z = 0..1)."""
    cells = [(x, y, z) for x in range(17) for y in range(8) for z in range(4) if x != 8 or (y == 4 and z <= 1)]
    w = World(cells)
    injected, t, forward = 0.0, 0.0, True
    while t < seconds:
        injected += w.inject((3, 4, 1), rate * dt, 30)
        w.step("smoke", dt, forward)
        forward = not forward
        t += dt
    w.check(injected)
    out = sum(v for (x, y, z), v in w.c.items() if x > 8) / injected
    print(f"door      {seconds:5.0f}s впрыск {injected:7.2f}  ушло через дверь {out * 100:5.1f}%")
    return out


z_smoke, f_smoke, _ = run_room("smoke")
_, _, haze_late = run_room("smoke", seconds=240.0)
z_cl, _, _ = run_room("chlorine")
z_me, _, _ = run_room("methane")
z_co, _, _ = run_room("co_smoke", seconds=6.0)
_, _, _ = run_room("smoke", seconds=10.0, rate=40.0)   # источник упирается в MAX_CONC — перелив
door_out = run_door(seconds=20.0)
assert z_cl < 1.0, "хлор должен лечь на пол"
assert z_me > 3.5, "метан должен подняться к потолку"
assert z_co > 2.5, "горячий дым пожара должен уйти вверх"
assert f_smoke > 0.6, "дым должен держать плотный объём, а не размазываться"
assert haze_late > 0.4, "за 4 минуты дым должен расплыться дымкой по комнате"
assert door_out > 0.05, "мощный источник должен выдавливать газ через дверь"
print("SOLVER PHYSICS OK")
