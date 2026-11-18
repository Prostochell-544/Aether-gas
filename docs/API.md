# Aether API (version 1)

**English** · [Русский](API.ru.md) · [Українська](API.uk.md)

`AetherGas.API` is the stable interface for other addons. Its function names, arguments and the hooks below stay compatible within one API version. The internal modules (`AetherGas.Solver`, `AetherGas.Spatial`) can change at any time, so don't depend on them.

```lua
if AetherGas and AetherGas.API and AetherGas.API.Version >= 1 then
    -- Aether is installed
end
```

A gas can be passed by name (`"chlorine"`) or by numeric id. Positions are world-space `Vector`s. Concentration runs from 0 to 1: 1 is a dense cloud, and the grid stores up to 3 right next to a source. Concentration above 1 is overpressure: it pushes gas out faster and forms jets through doors. Temperatures are in °C.

## Registering a gas (shared)

Register gases **from shared code, in the same order on server and client**. The gas id is its registration index and is sent over the network as a byte. The safest place is the `AetherGas.RegisterGases` hook, which fires once after Aether's own gases:

```lua
-- lua/autorun/my_gas.lua  (shared: AddCSLuaFile + runs on both realms)
AddCSLuaFile()
hook.Add("AetherGas.RegisterGases", "MyMod.Gases", function(register)
    register("my_spores", {
        printName = "Fungal Spores",
        density = 1.1,              -- relative to air at 20 °C; > 1 sinks, < 1 rises
        diffusion = 0.15, spread = 0.5, cohesion = 0.1, decay = 0.01,
        color = Color(150, 200, 90), opacity = 0.6, fogDistance = 500,
        damage = 3, damageType = DMG_POISON, damageThreshold = 0.1, maskProtects = true,
        screen = { cough = 0.8, blur = 0.3 },
        grenade = { 8, 16, 0 },     -- rate per second, duration in seconds, upward jet speed
    })
end)
```

If your file loads after Aether, you can also call `AetherGas.API.RegisterGas(name, def)` directly. Registering an existing name again updates it in place and keeps its id.

### Gas definition fields

Any field you leave out takes the default shown in brackets.

| Field | Meaning |
|---|---|
| `printName` | display name |
| `density` [1] | relative density at 20 °C. Buoyancy uses `ρ_eff = density · T_amb / T`, so hot gas rises and cold gas sinks |
| `diffusion` [0.15] | exchange with each open neighbour, 1/s |
| `spread` [0.5] | pressure equalisation (room filling), 0..1 |
| `cohesion` [0] | below this concentration the gas stops spreading, which gives the cloud an edge |
| `decay` [0.01] | dissipation under open sky, 1/s |
| `indoorDecay` [0.1] | decay multiplier indoors: gas in a closed room dilutes instead of vanishing. Use 1 for gases that condense or evaporate |
| `emitTemp` [20], `cooling` [0.05] | temperature at the source (°C) and how fast it relaxes to ambient |
| `color`, `opacity` [0.5] | look. With `opacity` < 0.005 the gas is not drawn at all |
| `fogDistance` [0] | how far you can see from inside the cloud at concentration 1, in units. 0 = no fog |
| `blocksVision`, `visionThreshold` [0.35] | blocks sight for players and NPCs above the threshold |
| `muffle` [0] | sound muffling inside the cloud, 0..1 |
| `damage` [0], `damageType`, `damageThreshold` [0.1] | HP per second at concentration 1, the damage type, and the concentration below which there is no damage |
| `maskProtects` [true] | whether a gas mask stops it |
| `skinDamage` [0] | share of the damage that a mask does not stop; only a suit does |
| `slowdown` [0] | movement slowdown at concentration 1 |
| `flammable`, `flameMin`, `flameMax`, `blastDamage`, `igniteOnBlast` | flammable window and the explosion of a single voxel |
| `condenses`, `condenseRate`, `condenseTemp` | condensation on cold walls (steam) |
| `extinguishes` | puts out fire inside the cloud |
| `screen` | screen effects: `cough`, `distortion`, `blur`, `narrow`, `darken`, `fog`, `shake` (0..1+) and `tint` (Color) |
| `grenade` [{8, 16, 30}] | grenade profile: rate, duration, upward jet speed |

Models have skins only for Aether's own gases. A third-party gas uses the neutral skin 0 on grenades and cylinders.

## Functions

### Shared (both realms)

| Function | Returns | Notes |
|---|---|---|
| `API.RegisterGas(name, def)` | id | see above |
| `API.GetGas(nameOrId)` | def table or nil | read-only |
| `API.GetGases()` | `{ name, ... }` | in id order |
| `API.Sample(pos)` | `name or nil, conc, temp` | on the client this reads the client's own simulation |
| `API.IsLineObscured(a, b)` | bool | the same test NPCs use to lose sight |
| `API.HasMask(ply)` | bool | Aether gas mask is worn |

### Server

| Function | Notes |
|---|---|
| `API.Emit(gas, pos, rate, opts)` → id | Continuous source. `rate` is concentration per second (a grenade is about 6–9). `opts`: `duration` (s, 0 = until `Stop`), `temp`, `vel` (jet Vector), `ent` (attach to an entity; `pos` and `vel` are then in its local space and the source dies with it) |
| `API.Puff(gas, pos, amount, radius, opts)` | One-shot cloud: `amount` concentration spread over a ball of `radius` voxels (0–3). `opts`: `temp`, `vel` |
| `API.Vacuum(pos, radius)` | removes all gas in a ball of `radius` voxels |
| `API.Stop(id)` | stops a source or sink |
| `API.Sink(pos, radius, rate, duration, ent)` → id | removes gas around `pos` (radius in units) and pulls the cloud toward it |
| `API.Push(a, b, radius, strength, dilute)` | flow along segment a→b (fan, extinguisher); `dilute` is 0..1 |
| `API.Blast(pos, radius, strength, noIgnite)` | shock wave; ignites flammable gas unless `noIgnite` |
| `API.Ignite(pos)` | ignites gas at a point, which starts a chain detonation if the mixture is within its limits |
| `API.Clear()` | removes all gas and sources |
| `API.GiveMask(ply, filterSeconds)`, `API.RemoveMask(ply, drop)` | Aether gas mask |
| `API.RegisterMaskProvider(name, fn, opts)` | `fn(ply, gasDef)` returns respiratory protection 0..1 (or `true`); Aether damage is multiplied by (1 − protection) . `opts.passDamage = true`: Aether still deals the gas damage so your mask can absorb it in `EntityTakeDamage` and spend its own filter |
| `API.SetCustomGas(slot, flat)` | sets the parameters of `"custom_1"`…`"custom_4"`; `flat` uses the fields of `AetherGas.CustomGasFields` |

Everything you do on the server reaches clients as small events; never send gas grids yourself.

### Spawning items from code

```lua
local g = ents.Create("aether_grenade")      -- releases gas after a 1.5 s fuse
g:SetPos(pos) g:SetGasName("tear_gas") g:Spawn()

local c = ents.Create("aether_canister")     -- E toggles the valve
c:SetKeyValue("gas", "ammonia") c:SetPos(pos) c:Spawn()
c:SetValve(true)
```

## Hooks

| Hook | Realm | Arguments → return |
|---|---|---|
| `AetherGas.RegisterGases` | shared | `(register)`: register your gases here |
| `AetherGas.GasRegistered` | shared | `(def)`: after any (re)registration |
| `AetherGas.CustomGasChanged` | shared | `(name, def)`: a custom slot was edited |
| `AetherGas.GridRebuilt` | shared | `()`: voxel size changed, so all gas is gone |
| `AetherGas.ClientReady` | server | `(ply)`: the client has loaded; send it your own state |
| `AetherGas.PreExposure` | server | `(ent, gasName, conc)` → `false` skips damage and effects for this tick (0.25 s) |
| `AetherGas.HasGasMask` | server | `(ply)` → `true` or 0..1: your mod's respiratory protection |
| `AetherGas.HasGasSuit` | server | `(ply)` → `true`: skin protection (sarin, mustard gas) |
| `AetherGas.ShouldBlind` | server | `(npc, enemy)` → `false`: the NPC is not blinded by smoke |
| `AetherGas.CanUseGasGun` | shared | `(ply, gasName)` → `false` forbids spraying this gas |
| `AetherGas.CanEditCustomGas` | server | `(ply, slot)` → `true`/`false` overrides who may edit custom gases |

## Examples

**Gas trap that triggers when a player enters a trigger:**

```lua
function ENT:StartTouch(ent)
    if ent:IsPlayer() and not self.Fired then
        self.Fired = true
        AetherGas.API.Emit("chlorine", self:GetPos(), 8, { duration = 12 })
    end
end
```

**Immunity for a custom player class:**

```lua
hook.Add("AetherGas.PreExposure", "MyMod.Immune", function(ent, gas)
    if ent:IsPlayer() and ent:GetNWBool("MyMod_Android") then return false end
end)
```

**Your own gas mask:**

```lua
AetherGas.API.RegisterMaskProvider("mymod_respirator", function(ply)
    return ply:GetNWBool("MyRespirator") and 0.8 or 0   -- 80 % protection
end)
```

**Detector:**

```lua
local name, conc = AetherGas.API.Sample(ply:EyePos())
if name == "methane" and conc > 0.05 then ply:ChatPrint("Explosive mixture!") end
```

## Rules for performance

- Don't call `Emit` every tick. Create one source and `Stop` it later, or use `Puff` at no more than about 10 Hz.
- `Sample` is cheap (a single voxel lookup), but don't run it in nested loops over many entities every frame.
- Aether stays within `aether_tick_budget` on its own, so external code cannot make it slower than that budget.
