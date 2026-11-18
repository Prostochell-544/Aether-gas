# Aether — Volumetric Smoke & Gas Dynamics

**English** · [Русский](README.ru.md) · [Українська](README.uk.md) · [API](docs/API.md)

A Garry's Mod addon that simulates gases in a sparse 3D voxel grid. It is written entirely in GLua and needs no binary modules.

Smoke fills rooms and pours through opened doors and broken windows. Chlorine creeps down stairs and pools in basements. Methane collects under the ceiling and goes off in a chain explosion. Fire smoke rises hot and fills a room from the top down.

## Features

- A time-sliced cellular-automaton solver moves the gas: buoyancy from density and temperature, pressure equalisation (flood fill), diffusion, advection, wind and decay. Collision is baked per voxel face, so even thin walls block gas.
- Opening a door, breaking glass or moving a big prop opens the passage. Detection is event-driven; nothing polls the whole map.
- A bullet through smoke clears a narrow line of sight that closes up in a couple of seconds. Explosions push gas outward and ignite flammable mixtures.
- 18 gases: tactical smoke, chlorine, methane, fire smoke (CO), steam, tear gas (CS), sarin, mustard gas, hydrogen sulfide, ammonia, hydrogen, cryogenic nitrogen fog, CO₂ and five signal smoke colours. Four more slots hold custom gases you design in-game.
- Only compact events go over the network (sources, bullet rays, explosions). Each client runs the same simulation; compressed chunk snapshots correct drift and catch up late joiners.

### Gameplay

- Toxic damage, coughing, tears, tunnel vision, convulsions, hypoxia and slowdown.
- Players and NPCs/NextBots can't see through dense smoke.
- Sound is muffled inside clouds.
- Gas mask with a limited filter and spare filters.
- Sarin and mustard gas also act through skin; only a hazmat suit stops them fully. Aether has its own hazmat suit; GMod Bombs 5 and JMod suits work too.

### Items and tools

- Grenades for every gas, plus an admin multi-grenade.
- Gas cylinders marked like real ones (NFPA 704, GHS, UN number), with a hose; an unmarked rusty cylinder for machinima.
- Propane tank that leaks with thrust and explodes.
- Exhaust fan (admin), blower fan, and duct vents linked with the tool gun.
- Gas analyzer.
- Gas Sprayer with an in-game custom gas editor.
- Hand signal flares in five colours: coloured light, sparks and a column of signal smoke for 45 s. A burning flare ignites flammable gas.

### Compatibility

- Gas masks and suits from GMod Bombs 5, JMod and "Rebirth" Gas Mask (& Base) by Hidden — its filter is spent by Aether gases.
- Fire from vFire, Fire Tool and burning props: fires make smoke, flammable gas explodes into vFire flames, CO₂ and nitrogen put fires out.
- StormFox 2 wind; WAC and LVS helicopter rotor wash; fire extinguishers.
- Procedural Wall Destruction; DrGBase and VJ Base NPCs.

## Installation

- **Steam Workshop:** subscribe to the item.
- **Manual:** clone or download this repository into `garrysmod/addons/aether_gas` (the folder must contain `addon.json` and `lua/`).

The addon is server-side and client-side Lua plus materials and models. Every client receives the files automatically from the server.

## How to play

| Item | Where | Controls |
|---|---|---|
| Gas grenades | Weapons → Aether Gas → `Grenade: …` | LMB throw, RMB lob |
| Multi-grenade (admin) | Weapons → `Grenade: ALL GASES` | R cycles the gas |
| Gas cylinders | Entities → Aether Gas → `Cylinder: …` | E opens or closes the valve. C-menu → *Gas type* / *Turn on/off* / *Unmarked (old) look*. `Cylinder: Unmarked (old)` is a rusty cylinder with no labels, for machinima |
| Signal flares | Weapons → `Signal Flare`; Entities → `Flare: …` | LMB light and throw, RMB light and drop at your feet, R changes the colour |
| Gas Sprayer | Weapons → `Gas Sprayer` | LMB spray, RMB settings and custom gas editor, R removes gas at aim |
| Gas analyzer | Weapons → `Gas Analyzer` | LMB switches the probe between breathing zone and aim point. RMB cycles device screen / HUD |
| Spare filter | Entities → `Gas Mask Filter` | E: if the mask filter is below half, it is replaced right away; otherwise the filter is kept as a spare (up to 3). A spare is screwed in automatically when the current filter runs out |
| Gas mask | Entities → `Gas Mask` | E puts it on. `!mask` (or hold E and press R) takes it off / puts it back on. `aether_mask_drop` drops it |
| Hazmat suit | Entities → `Hazmat Suit` | E puts it on: full protection from every gas, half from steam burns, 10 % slower. `!suit` takes it off |
| Duct / hose | Tool gun → Aether Gas → `Gas Duct / Hose` | LMB on a cylinder, then LMB where the nozzle goes. Or LMB on a wall for the intake vent, then LMB for the exhaust vent. E on a vent starts pumping |
| Emitter | Tool gun → `Gas Emitter` | LMB places an emitter, RMB releases one puff |
| Fans | Entities → `Blower Fan`, `Exhaust Fan (Admin)` | E turns it on. The blower pushes gas out of its grille; the exhaust fan removes gas |

Settings: **Q → Utilities → Aether Gas** (client settings for everyone, server settings for superadmins).

### Gases

| Gas | Behaviour | Danger | Gas mask |
|---|---|---|---|
| Tactical Smoke | fills rooms, blocks sight | none | — |
| Chlorine | heavy, creeps along the floor | toxic, coughing | protects |
| Methane | light, invisible, rises | explosive (5–90 %) | — |
| Fire Smoke (CO) | hot, rises, then fills from the top | asphyxiation, darkening | does **not** protect |
| Steam | hot, rises, condenses on walls | burns, fogs the screen | does not protect |
| Tear Gas (CS) | slightly heavy | tears, coughing, blur | protects |
| Sarin (GB) | heavy, colourless | lethal, tunnel vision, convulsions | 70 %, a suit protects fully |
| Mustard Gas (HD) | heavy, very persistent | blistering | 50 %, a suit protects fully |
| Hydrogen Sulfide | slightly heavy, pools in basements | toxic and flammable | protects |
| Ammonia | released cold, then rises | corrosive, burns eyes | protects |
| Hydrogen | lightest, invisible | strongly explosive | — |
| Cryogenic Nitrogen Fog | icy white blanket on the floor | asphyxiation, slowdown | does not protect |
| Carbon Dioxide | heavy, invisible, puts out fire | asphyxiation | does not protect |
| Signal Smoke ×5 | coloured marker smoke | none | — |
| Custom 1–4 | whatever you design | your choice | your choice |

## Console variables

**Client**

| Variable | Default | Description |
|---|---|---|
| `aether_draw` | 1 | draw gas clouds |
| `aether_draw_distance` | 6000 | draw distance, units |
| `aether_mesh_budget` | 1.5 | mesh rebuild budget, ms per frame |
| `aether_effects` | 1 | screen effects |
| `aether_analyzer_screen`, `_hud`, `_beep`, `_marker` | 1 | analyzer interfaces |
| `aether_gun_gas`, `_rate`, `_distance`, `_spread`, `_velocity`, `_temp`, `_mode` | — | Gas Sprayer settings (also in its menu) |

**Server**

| Variable | Default | Description |
|---|---|---|
| `aether_enabled` | 1 | simulation on/off |
| `aether_voxel_size` | 40 | voxel size 32–128: smaller is finer but costs more CPU (changing it resets all gas) |
| `aether_max_chunks` | 512 | active 8×8×8 chunk limit |
| `aether_tick_budget` | 1.5 | solver budget, ms per tick |
| `aether_probe_budget` | 48 | collision traces per tick |
| `aether_grates_block` | 0 | grates and meshes block gas |
| `aether_wind_speed`, `aether_wind_yaw` | 0, 0 | global wind |
| `aether_wind_stormfox` | 1 | take wind from StormFox 2 |
| `aether_damage_scale` | 1 | gas damage multiplier (0 = harmless) |
| `aether_npc_blind` | 1 | smoke blinds NPCs and NextBots |
| `aether_mask_filter` | 240 | gas mask filter, seconds in toxic gas |
| `aether_sync_interval` | 0.5 | chunk snapshot interval, seconds |
| `aether_custom_gas_everyone` | 0 | everyone (not only admins) may edit custom gases |
| `aether_gasgun_toxic_admin` | 0 | only admins may spray toxic or flammable gases |
| `aether_tunnel_strength` | 0.85 | how much gas a bullet knocks out along its path (0 = bullets don't cut smoke) |
| `aether_fire_smoke` | 1 | smoke from fire (vFire, env_fire, burning props); 0 = fire makes no smoke |
| `aether_fire_vfire` | 1 | gas explosions spread vFire fire |
| `aether_vfire_wind` | 1 | vFire flames lean with Aether wind |

**Commands:**
- `aether_spawn <gas> [rate] [seconds]`, `aether_clear`, `aether_ignite` (superadmin or singleplayer);
- `aether_mask_toggle`, `aether_mask_drop`;
- `aether_compat_report`;
- `aether_debug_grid`, `aether_debug_probe`, `aether_debug_bake`, `aether_debug_stats`, `aether_debug_reset`.

## Performance

- The solver stays within `aether_tick_budget` per tick and works only on chunks that contain gas.
- Collision faces are traced lazily, once each, and cached.
- The client draws one cached mesh per chunk (≤ 2048 vertices) and rebuilds only changed chunks within `aether_mesh_budget`.
- A larger `aether_voxel_size` means cheaper but coarser clouds.

## For modders

Use the stable `AetherGas.API` facade: register gases, emit and sample gas, add mask providers, and react through hooks. See [docs/API.md](docs/API.md).

```lua
hook.Add("AetherGas.RegisterGases", "MyMod", function(register)
    register("my_spores", { printName = "Spores", density = 1.1, color = Color(150, 200, 90),
        opacity = 0.6, damage = 3, damageType = DMG_POISON, maskProtects = true })
end)
```

## Building assets

Models, textures and icons are generated by `tools/make_models.py`, which needs Python 3, Pillow, numpy and GMod's own `studiomdl.exe` / `vtex.exe`. Offline checks:

```
python -I tools/luacheck51.py <files>
python -I tools/test_bitmath.py
python -I tools/test_solver_physics.py
```

## License

[CC BY-NC-SA 4.0](LICENSE): free to use and modify with credit, no commercial use. Other addons may call the API and hooks without adopting this license.
