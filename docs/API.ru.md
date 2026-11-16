# Aether API (версия 1)

[English](API.md) · **Русский** · [Українська](API.uk.md)

`AetherGas.API` — стабильный интерфейс для других аддонов. Имена функций, аргументы и хуки ниже не меняются в пределах одной версии API. Внутренние модули (`AetherGas.Solver`, `AetherGas.Spatial`) могут меняться в любой момент, на них не опирайтесь.

```lua
if AetherGas and AetherGas.API and AetherGas.API.Version >= 1 then
    -- Aether установлен
end
```

Газ можно передать по имени (`"chlorine"`) или по числовому id. Позиции — `Vector` в мировых координатах. Концентрация от 0 до 1: 1 — плотное облако, а вплотную к источнику в сетке может быть до 2. Температура в °C.

## Регистрация газа (shared)

Регистрируйте газы **из shared-кода, в одинаковом порядке на сервере и клиенте**. Id газа — порядковый номер регистрации, и по сети он передаётся одним байтом. Надёжнее всего делать это в хуке `AetherGas.RegisterGases`: он срабатывает один раз, после газов самого Aether.

```lua
-- lua/autorun/my_gas.lua  (shared: AddCSLuaFile + выполняется в обоих реалмах)
AddCSLuaFile()
hook.Add("AetherGas.RegisterGases", "MyMod.Gases", function(register)
    register("my_spores", {
        printName = "Fungal Spores",
        density = 1.1,              -- относительно воздуха при 20 °C; > 1 оседает, < 1 всплывает
        diffusion = 0.15, spread = 0.5, cohesion = 0.1, decay = 0.01,
        color = Color(150, 200, 90), opacity = 0.6, fogDistance = 500,
        damage = 3, damageType = DMG_POISON, damageThreshold = 0.1, maskProtects = true,
        screen = { cough = 0.8, blur = 0.3 },
        grenade = { 8, 16, 0 },     -- скорость в секунду, длительность в секундах, струя вверх
    })
end)
```

Если ваш файл грузится после Aether, можно вызвать `AetherGas.API.RegisterGas(name, def)` напрямую. Повторная регистрация того же имени обновляет газ на месте и сохраняет id.

### Поля описания газа

Не указанное поле получает значение по умолчанию (в квадратных скобках).

| Поле | Смысл |
|---|---|
| `printName` | отображаемое имя |
| `density` [1] | относительная плотность при 20 °C. Плавучесть считается как `ρ_eff = density · T_amb / T`: горячий газ поднимается, холодный оседает |
| `diffusion` [0.15] | обмен с каждым открытым соседом, 1/с |
| `spread` [0.5] | выравнивание давления (заполнение помещения), 0..1 |
| `cohesion` [0] | ниже этой концентрации газ перестаёт растекаться — у облака появляется край |
| `decay` [0.01] | рассеивание, 1/с. Под открытым небом быстрее |
| `emitTemp` [20], `cooling` [0.05] | температура у источника (°C) и скорость остывания до окружающей |
| `color`, `opacity` [0.5] | внешний вид. При `opacity` < 0.005 газ не рисуется вовсе |
| `fogDistance` [0] | на сколько видно изнутри облака при концентрации 1, юниты. 0 — без тумана |
| `blocksVision`, `visionThreshold` [0.35] | выше порога закрывает обзор игрокам и NPC |
| `muffle` [0] | приглушение звука в облаке, 0..1 |
| `damage` [0], `damageType`, `damageThreshold` [0.1] | урон в HP/с при концентрации 1, тип урона и концентрация, ниже которой урона нет |
| `maskProtects` [true] | защищает ли противогаз |
| `skinDamage` [0] | доля урона, которую противогаз не снимает; снимает только костюм |
| `slowdown` [0] | замедление движения при концентрации 1 |
| `flammable`, `flameMin`, `flameMax`, `blastDamage`, `igniteOnBlast` | пределы воспламенения и взрыв одного вокселя |
| `condenses`, `condenseRate`, `condenseTemp` | конденсация на холодных стенах (пар) |
| `extinguishes` | тушит огонь внутри облака |
| `screen` | экранные эффекты: `cough`, `distortion`, `blur`, `narrow`, `darken`, `fog`, `shake` (0..1+) и `tint` (Color) |
| `grenade` [{8, 16, 30}] | профиль гранаты: скорость, длительность, струя вверх |

Скины моделей есть только у газов самого Aether. Сторонний газ на гранате и баллоне получает нейтральный скин 0.

## Функции

### Общие (оба реалма)

| Функция | Возвращает | Примечание |
|---|---|---|
| `API.RegisterGas(name, def)` | id | см. выше |
| `API.GetGas(nameOrId)` | описание или nil | только чтение |
| `API.GetGases()` | `{ имя, ... }` | в порядке id |
| `API.Sample(pos)` | `имя или nil, конц., темп.` | на клиенте читает собственную симуляцию клиента |
| `API.IsLineObscured(a, b)` | bool | та же проверка, по которой NPC теряют цель |
| `API.HasMask(ply)` | bool | надет противогаз Aether |

### Сервер

| Функция | Примечание |
|---|---|
| `API.Emit(gas, pos, rate, opts)` → id | Постоянный источник. `rate` — концентрации в секунду (граната — около 6–9). `opts`: `duration` (с, 0 — до `Stop`), `temp`, `vel` (струя, Vector), `ent` (привязка к сущности: `pos` и `vel` тогда в её локальных координатах, источник умирает вместе с ней) |
| `API.Puff(gas, pos, amount, radius, opts)` | Разовое облачко: `amount` концентрации в шар радиуса `radius` вокселей (0–3). `opts`: `temp`, `vel` |
| `API.Vacuum(pos, radius)` | убрать весь газ в шаре радиуса `radius` вокселей |
| `API.Stop(id)` | остановить источник или сток |
| `API.Sink(pos, radius, rate, duration, ent)` → id | убирает газ вокруг `pos` (радиус в юнитах) и тянет облако к себе |
| `API.Push(a, b, radius, strength, dilute)` | поток вдоль отрезка a→b (вентилятор, огнетушитель); `dilute` — 0..1 |
| `API.Blast(pos, radius, strength, noIgnite)` | ударная волна; поджигает горючий газ, если не задан `noIgnite` |
| `API.Ignite(pos)` | поджечь газ в точке; если смесь в пределах воспламенения, начнётся цепная детонация |
| `API.Clear()` | удалить весь газ и все источники |
| `API.GiveMask(ply, filterSeconds)`, `API.RemoveMask(ply, drop)` | противогаз Aether |
| `API.RegisterMaskProvider(name, fn)` | `fn(ply)` возвращает защиту дыхания 0..1 (или `true`); урон Aether умножается на (1 − защита) |
| `API.SetCustomGas(slot, flat)` | задать параметры `"custom_1"`…`"custom_4"`; `flat` — поля из `AetherGas.CustomGasFields` |

Всё, что вы делаете на сервере, доходит до клиентов маленькими событиями. Сами сетки газа по сети не отправляйте.

### Создание предметов из кода

```lua
local g = ents.Create("aether_grenade")      -- выпускает газ через 1.5 с
g:SetPos(pos) g:SetGasName("tear_gas") g:Spawn()

local c = ents.Create("aether_canister")     -- E открывает и закрывает вентиль
c:SetKeyValue("gas", "ammonia") c:SetPos(pos) c:Spawn()
c:SetValve(true)
```

## Хуки

| Хук | Реалм | Аргументы → возврат |
|---|---|---|
| `AetherGas.RegisterGases` | shared | `(register)`: регистрируйте свои газы здесь |
| `AetherGas.GasRegistered` | shared | `(def)`: после любой (пере)регистрации |
| `AetherGas.CustomGasChanged` | shared | `(name, def)`: изменён слот своего газа |
| `AetherGas.GridRebuilt` | shared | `()`: сменился размер вокселя, весь газ пропал |
| `AetherGas.ClientReady` | server | `(ply)`: клиент загрузился; отправьте ему своё состояние |
| `AetherGas.PreExposure` | server | `(ent, gasName, conc)` → `false` пропускает урон и эффекты на этот тик (0.25 с) |
| `AetherGas.HasGasMask` | server | `(ply)` → `true` или 0..1: защита дыхания вашего мода |
| `AetherGas.HasGasSuit` | server | `(ply)` → `true`: защита кожи (зарин, иприт) |
| `AetherGas.ShouldBlind` | server | `(npc, enemy)` → `false`: дым не ослепляет этого NPC |
| `AetherGas.CanUseGasGun` | shared | `(ply, gasName)` → `false` запрещает распылять этот газ |
| `AetherGas.CanEditCustomGas` | server | `(ply, slot)` → `true`/`false` переопределяет, кто может менять свои газы |

## Примеры

**Газовая ловушка, срабатывает, когда игрок входит в триггер:**

```lua
function ENT:StartTouch(ent)
    if ent:IsPlayer() and not self.Fired then
        self.Fired = true
        AetherGas.API.Emit("chlorine", self:GetPos(), 8, { duration = 12 })
    end
end
```

**Иммунитет для своего класса игрока:**

```lua
hook.Add("AetherGas.PreExposure", "MyMod.Immune", function(ent, gas)
    if ent:IsPlayer() and ent:GetNWBool("MyMod_Android") then return false end
end)
```

**Свой противогаз:**

```lua
AetherGas.API.RegisterMaskProvider("mymod_respirator", function(ply)
    return ply:GetNWBool("MyRespirator") and 0.8 or 0   -- защита 80 %
end)
```

**Детектор:**

```lua
local name, conc = AetherGas.API.Sample(ply:EyePos())
if name == "methane" and conc > 0.05 then ply:ChatPrint("Взрывоопасная смесь!") end
```

## Правила производительности

- Не вызывайте `Emit` каждый тик. Создайте один источник и потом остановите его через `Stop`, либо используйте `Puff` не чаще примерно 10 раз в секунду.
- `Sample` дешёвый (одно обращение к вокселю), но не гоняйте его во вложенных циклах по множеству сущностей каждый кадр.
- Aether сам держится в пределах `aether_tick_budget`, поэтому внешний код не сделает его медленнее этого бюджета.
