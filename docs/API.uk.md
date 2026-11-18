# Aether API (версія 1)

[English](API.md) · [Русский](API.ru.md) · **Українська**

`AetherGas.API` — стабільний інтерфейс для інших аддонів. Імена функцій, аргументи та хуки нижче не змінюються в межах однієї версії API. Внутрішні модулі (`AetherGas.Solver`, `AetherGas.Spatial`) можуть змінюватися будь-коли, тож на них не спирайтеся.

```lua
if AetherGas and AetherGas.API and AetherGas.API.Version >= 1 then
    -- Aether встановлено
end
```

Газ можна передати за іменем (`"chlorine"`) або за числовим id. Позиції — `Vector` у світових координатах. Концентрація від 0 до 1: 1 — щільна хмара, а впритул до джерела в сітці може бути до 3. Концентрація понад 1 — надлишковий тиск: газ виштовхується швидше й б'є струменем у двері. Температура в °C.

## Реєстрація газу (shared)

Реєструйте гази **зі shared-коду, в однаковому порядку на сервері й клієнті**. Id газу — порядковий номер реєстрації, і мережею він передається одним байтом. Найнадійніше робити це в хуку `AetherGas.RegisterGases`: він спрацьовує один раз, після газів самого Aether.

```lua
-- lua/autorun/my_gas.lua  (shared: AddCSLuaFile + виконується в обох реалмах)
AddCSLuaFile()
hook.Add("AetherGas.RegisterGases", "MyMod.Gases", function(register)
    register("my_spores", {
        printName = "Fungal Spores",
        density = 1.1,              -- відносно повітря за 20 °C; > 1 осідає, < 1 спливає
        diffusion = 0.15, spread = 0.5, cohesion = 0.1, decay = 0.01,
        color = Color(150, 200, 90), opacity = 0.6, fogDistance = 500,
        damage = 3, damageType = DMG_POISON, damageThreshold = 0.1, maskProtects = true,
        screen = { cough = 0.8, blur = 0.3 },
        grenade = { 8, 16, 0 },     -- швидкість за секунду, тривалість у секундах, струмінь угору
    })
end)
```

Якщо ваш файл вантажиться після Aether, можна викликати `AetherGas.API.RegisterGas(name, def)` напряму. Повторна реєстрація того самого імені оновлює газ на місці й зберігає id.

### Поля опису газу

Незазначене поле отримує значення за замовчуванням (у квадратних дужках).

| Поле | Зміст |
|---|---|
| `printName` | ім'я для показу |
| `density` [1] | відносна густина за 20 °C. Плавучість рахується як `ρ_eff = density · T_amb / T`: гарячий газ піднімається, холодний осідає |
| `diffusion` [0.15] | обмін із кожним відкритим сусідом, 1/с |
| `spread` [0.5] | вирівнювання тиску (заповнення приміщення), 0..1 |
| `cohesion` [0] | нижче цієї концентрації газ перестає розтікатися — у хмари з'являється край |
| `decay` [0.01] | розсіювання під відкритим небом, 1/с |
| `indoorDecay` [0.1] | множник розсіювання в приміщенні: газ у закритій кімнаті розбавляється, а не зникає. 1 — для газів, що конденсуються або випаровуються |
| `emitTemp` [20], `cooling` [0.05] | температура біля джерела (°C) і швидкість остигання до навколишньої |
| `color`, `opacity` [0.5] | вигляд. Якщо `opacity` < 0.005, газ не малюється взагалі |
| `fogDistance` [0] | наскільки далеко видно зсередини хмари за концентрації 1, юніти. 0 — без туману |
| `blocksVision`, `visionThreshold` [0.35] | вище порогу закриває огляд гравцям і NPC |
| `muffle` [0] | приглушення звуку в хмарі, 0..1 |
| `damage` [0], `damageType`, `damageThreshold` [0.1] | шкода в HP/с за концентрації 1, тип шкоди й концентрація, нижче якої шкоди немає |
| `maskProtects` [true] | чи захищає протигаз |
| `skinDamage` [0] | частка шкоди, яку протигаз не знімає; знімає лише костюм |
| `slowdown` [0] | сповільнення руху за концентрації 1 |
| `flammable`, `flameMin`, `flameMax`, `blastDamage`, `igniteOnBlast` | межі займання та вибух одного воксела |
| `condenses`, `condenseRate`, `condenseTemp` | конденсація на холодних стінах (пара) |
| `extinguishes` | гасить вогонь усередині хмари |
| `screen` | екранні ефекти: `cough`, `distortion`, `blur`, `narrow`, `darken`, `fog`, `shake` (0..1+) і `tint` (Color) |
| `clearance` [30], `linger` [0.25] | час виведення дози (с) і частка шкоди та ефектів від накопиченої дози |
| `deposit` [0] | частка за секунду, що осідає на підлогу й шкіру (зараження) |
| `jtCooling` [0] | на скільки °C газ охолоджується при випуску з балона |
| `grenade` [{8, 16, 30}] | профіль гранати: швидкість, тривалість, струмінь угору |

Скіни моделей є лише в газів самого Aether. Сторонній газ на гранаті й балоні отримує нейтральний скін 0.

## Функції

### Спільні (обидва реалми)

| Функція | Повертає | Примітка |
|---|---|---|
| `API.RegisterGas(name, def)` | id | див. вище |
| `API.GetGas(nameOrId)` | опис або nil | лише читання |
| `API.GetGases()` | `{ ім'я, ... }` | у порядку id |
| `API.Sample(pos)` | `ім'я або nil, конц., темп.` | на клієнті читає власну симуляцію клієнта |
| `API.IsLineObscured(a, b)` | bool | та сама перевірка, за якою NPC втрачають ціль |
| `API.HasMask(ply)` | bool | вдягнено протигаз Aether |

### Сервер

| Функція | Примітка |
|---|---|
| `API.Emit(gas, pos, rate, opts)` → id | Постійне джерело. `rate` — концентрації за секунду (граната — близько 6–9). `opts`: `duration` (с, 0 — до `Stop`), `temp`, `vel` (струмінь, Vector), `ent` (прив'язка до сутності: `pos` і `vel` тоді в її локальних координатах, джерело зникає разом із нею) |
| `API.Puff(gas, pos, amount, radius, opts)` | Разова хмаринка: `amount` концентрації в кулю радіуса `radius` вокселів (0–3). `opts`: `temp`, `vel` |
| `API.Vacuum(pos, radius)` | прибрати весь газ у кулі радіуса `radius` вокселів |
| `API.Stop(id)` | зупинити джерело або стік |
| `API.Sink(pos, radius, rate, duration, ent)` → id | прибирає газ навколо `pos` (радіус у юнітах) і тягне хмару до себе |
| `API.Push(a, b, radius, strength, dilute)` | потік уздовж відрізка a→b (вентилятор, вогнегасник); `dilute` — 0..1 |
| `API.Blast(pos, radius, strength, noIgnite)` | ударна хвиля; підпалює горючий газ, якщо не задано `noIgnite` |
| `API.Ignite(pos)` | підпалити газ у точці; якщо суміш у межах займання, почнеться ланцюгова детонація |
| `API.Clear()` | прибрати весь газ і всі джерела |
| `API.GiveMask(ply, filterSeconds)`, `API.RemoveMask(ply, drop)` | протигаз Aether |
| `API.RegisterMaskProvider(name, fn, opts)` | `fn(ply, gasDef)` повертає захист дихання 0..1 (або `true`); шкода Aether множиться на (1 − захист). `opts.passDamage = true`: Aether однаково завдає шкоди газу, щоб ваша маска поглинула її в `EntityTakeDamage` і витратила свій фільтр |
| `API.SetCustomGas(slot, flat)` | задати параметри `"custom_1"`…`"custom_4"`; `flat` — поля з `AetherGas.CustomGasFields` |

Усе, що ви робите на сервері, доходить до клієнтів маленькими подіями. Самі сітки газу мережею не надсилайте.

### Створення предметів із коду

```lua
local g = ents.Create("aether_grenade")      -- випускає газ через 1.5 с
g:SetPos(pos) g:SetGasName("tear_gas") g:Spawn()

local c = ents.Create("aether_canister")     -- E відкриває й закриває вентиль
c:SetKeyValue("gas", "ammonia") c:SetPos(pos) c:Spawn()
c:SetValve(true)
```

## Хуки

| Хук | Реалм | Аргументи → повернення |
|---|---|---|
| `AetherGas.RegisterGases` | shared | `(register)`: реєструйте свої гази тут |
| `AetherGas.GasRegistered` | shared | `(def)`: після будь-якої (пере)реєстрації |
| `AetherGas.CustomGasChanged` | shared | `(name, def)`: змінено слот власного газу |
| `AetherGas.GridRebuilt` | shared | `()`: змінився розмір воксела, весь газ зник |
| `AetherGas.ClientReady` | server | `(ply)`: клієнт завантажився; надішліть йому свій стан |
| `AetherGas.PreExposure`, `Aether_PreGasExposure` | server | `(ent, gasName, conc, deltaDose)` → `false` пропускає шкоду й ефекти на цей тік (0.25 с) |
| `AetherGas.HasGasMask` | server | `(ply)` → `true` або 0..1: захист дихання вашого мода |
| `AetherGas.HasGasSuit` | server | `(ply)` → `true`: захист шкіри (зарин, іприт) |
| `AetherGas.ShouldBlind` | server | `(npc, enemy)` → `false`: дим не засліплює цього NPC |
| `AetherGas.CanUseGasGun` | shared | `(ply, gasName)` → `false` забороняє розпилювати цей газ |
| `AetherGas.CanEditCustomGas` | server | `(ply, slot)` → `true`/`false` перевизначає, хто може змінювати власні гази |

## Приклади

**Газова пастка, спрацьовує, коли гравець заходить у тригер:**

```lua
function ENT:StartTouch(ent)
    if ent:IsPlayer() and not self.Fired then
        self.Fired = true
        AetherGas.API.Emit("chlorine", self:GetPos(), 8, { duration = 12 })
    end
end
```

**Імунітет для власного класу гравця:**

```lua
hook.Add("AetherGas.PreExposure", "MyMod.Immune", function(ent, gas)
    if ent:IsPlayer() and ent:GetNWBool("MyMod_Android") then return false end
end)
```

**Власний протигаз:**

```lua
AetherGas.API.RegisterMaskProvider("mymod_respirator", function(ply)
    return ply:GetNWBool("MyRespirator") and 0.8 or 0   -- захист 80 %
end)
```

**Детектор:**

```lua
local name, conc = AetherGas.API.Sample(ply:EyePos())
if name == "methane" and conc > 0.05 then ply:ChatPrint("Вибухонебезпечна суміш!") end
```

## Правила продуктивності

- Не викликайте `Emit` кожен тік. Створіть одне джерело й потім зупиніть його через `Stop`, або використовуйте `Puff` не частіше приблизно 10 разів на секунду.
- `Sample` дешевий (одне звернення до воксела), але не ганяйте його у вкладених циклах по багатьох сутностях кожен кадр.
- Aether сам тримається в межах `aether_tick_budget`, тож зовнішній код не зробить його повільнішим за цей бюджет.
