# Changelog

## 0.11.0 — separate hazmat suit, three languages

- **Hazmat suit protects the skin only.** It no longer works as a gas mask (no respirator, no mask overlay). Breathing is protected by a gas mask, the skin by the suit: sarin and mustard gas need both. Damage = inhaled part × (1 − mask) + skin part × (1 − suit). The suit still halves steam burns and stops new contamination.
- **No more washing off in water.** Contamination keeps burning until the agent wears off, and a suit put on after you are contaminated no longer helps.
- The Aether suit no longer sets the GMod Bombs `hazsuited` flag.
- **Interface in English, Russian and Ukrainian.** Q menu, sprayer and custom gas editor, tool texts, HUD, gas names and server messages. Choose in Q → Utilities → Aether Gas → Language, or `aether_language auto|en|ru|uk` (Auto follows the game language). Server messages are sent as string keys, so every player reads them in their own language.
- Signal flares smoke much less (1.0 instead of 3.5 per second): a thin coloured trail instead of a room-filling cloud.
- API: `AetherGas.L(key, ...)`, `AetherGas.GasName(def)`, `AetherGas.Notify(ply, mode, key, ...)` (server).

## 0.10.0 — dose, contamination, cold gas, Wiremod, Z-City and GSmoke

- **Dose and lasting effects.** Inhaled gas builds up a dose that leaves the body over time (`clearance`, seconds). Part of the harm and screen effects (`linger`) comes from the dose, so sarin and mustard gas keep hurting after you leave the cloud, tear gas keeps the tears going, CO keeps the screen dark, and coughing continues until the dose clears.
- **Contamination.** Persistent agents (mustard gas, sarin, tear gas, a little chlorine; `deposit`) settle on floors and slowly off-gas for minutes. Without a hazmat suit they also settle on the player: skin burns and a trace of gas around you until you wash it off in water. The HUD shows "CONTAMINATED".
- **Cold gas (Joule–Thomson / evaporation).** Gas released from a cylinder comes out cold (`jtCooling`): CO2, ammonia and chlorine strongly, methane and H2S less, hydrogen not at all (above its inversion temperature it does not cool). White condensation mist at the valve and leaks; frost at the screen edges point-blank. Cold gas sinks.
- **Wiremod.** Cylinders, emitters, fans, blowers and vents get inputs `On`/`Open`, `Toggle`, `Rate`, `Detonate` (cylinder) and outputs `On`, `GasAmount`, `IsPunctured`, `Leaks`.
- **Valve Group tool.** Link many devices to one key and open them all at once; R toggles every device in a radius.
- Hazmat suit comes off with E+Alt or the Q-menu button, not only `!suit`.
- **Compatibility:** Z-City (its M40 gas mask and Combine players), GChem (mask and suit), GSmoke (exhaled cigarette and vape smoke enters the grid; a lit cigarette ignites flammable gas).
- New harmless `tobacco_smoke` gas. Custom gases get the new fields in the editor.
- API: `AetherGas.PreExposure` / `Aether_PreGasExposure` hooks get the dose increment as the 4th argument; `API.GetDose`, `API.Decontaminate`, `API.SetDeviceOn`.

## 0.9.2 — fixes from Workshop feedback

- Gas cylinders can be punctured: bullets, buckshot, crossbow bolts, blades and hard impacts open up to 3 leaks that jet gas out with thrust and drain the cylinder, whatever the valve state.
- Flammable cylinders (hydrogen, methane, hydrogen sulfide…) explode from fire, explosions, shock/energy (AR2) and high-calibre bullets (over 25 damage, except crossbow). 9 mm and buckshot only puncture them. In a fire they explode after 2 s. Non-flammable cylinders burst from explosions and vent through the relief valve in a fire.
- Bullets no longer ignite gas just by flying through a cloud. Gas ignites from muzzle flash (shooter inside the mixture), impact sparks on metal, grates and machinery (sometimes on concrete and tile, never on flesh), AR2 energy shots, explosions and fire.
- Exposure is sampled at eyes, waist (70 % of a breath) and feet (30 %), so standing chest-deep in chlorine hurts. The top of a cloud is drawn level with the simulated cells.
- Gas mask: E on a mask puts it on (or swaps in its fresher filter). Clear prompts name the other mod's mask that blocks it. `!mask` works as before.
- New Hazmat Suit entity: full protection from every gas (half from steam burns), 10 % slower, `!suit` takes it off, drops on death.
- Compatibility with "Rebirth" Gas Mask (& Base) by Hidden: the mask protects from Aether gases and its filter is spent.
- API: `RegisterMaskProvider(name, fn, opts)` — `fn` gets the gas definition; `opts.passDamage` lets a mask absorb the damage itself.

## 0.9.1 — gas pressure and airflow

Based on the first player feedback.

- A source that fills its cell no longer loses gas: the excess spills into neighbouring cells with an outward push. Cells hold up to 3 units instead of 2.
- Concentration above 1 is overpressure. It pushes gas through every open face, speeds the cell up along the pressure drop, and pushes foreign gas aside. A filled room now forces gas out through a door as a jet.
- Indoors, gases barely decay (`indoorDecay`, default 0.1). In a closed room gas dilutes and spreads as haze instead of disappearing. Steam and nitrogen fog still vanish at the full rate.
- A slow leak through cohesion: a cloud keeps its edge for about half a minute, then evens out over the room within a few minutes.
- Hand signal flares (`weapon_aether_flare`, `aether_flare`) in five colours: coloured dynamic light, sparks and 45 s of signal smoke. A lit flare ignites flammable gas and goes out in water.
- Cloud sprites shrink near floors, ceilings and walls (up to 1.5 voxels away) and no longer cut into them with a hard straight line.

## 0.9.0 — first public beta

**Simulation**
- Sparse voxel grid with 8³ chunks and a voxel size of 32–128 units (`aether_voxel_size`).
- Collision is baked lazily per face, so thin walls block gas.
- Doors, windows, breakables and big props open and close passages through events, without polling the map.
- Time-sliced conservative solver:
  - buoyancy from density and temperature;
  - pressure equalisation and diffusion;
  - cohesion, which gives clouds an edge;
  - advection, wind (including StormFox 2), sky sink, decay and condensation.
- Bullet tunnels, explosions and chain detonation of flammable mixtures.

**Gases (18 + 4 custom)**
- Smoke, chlorine, methane, fire smoke (CO), steam, tear gas (CS), sarin, mustard gas, hydrogen sulfide, ammonia, hydrogen, cryogenic nitrogen fog, CO₂, and signal smoke in red, green, yellow, violet and orange.
- Four custom gas slots, edited in-game with the Gas Sprayer and saved on the server.

**Items**
- Grenades for every gas, plus an admin multi-grenade.
- Gas cylinders with real-world hazard markings and a hose, plus an unmarked rusty cylinder for machinima.
- Propane tank that leaks with thrust and explodes.
- Exhaust fan (admin), blower fan, and duct vents linked with the tool gun.
- Gas mask, gas analyzer, Gas Sprayer.
- Gas emitter tool, and *Gas type* / *Turn on/off* in the C-menu.

**Effects**
- Engine fog inside clouds; sprites near the camera fade out.
- Coughing, tears, tunnel vision, convulsions, hypoxia, steam fogging and muffled sound.
- Gas mask view with breath fogging.
- NPCs and NextBots are blinded by smoke.

**Fire**
- Every fire (vFire, env_fire from Fire Tool and maps, burning props) emits fire smoke, sized by the fire. Smoke from all fires is merged per voxel and sent as one batch.
- Flammable gas explosions spread vFire fire. CO₂ and nitrogen put out fires (vFire is put out softly).
- vFire flames lean with Aether wind.

**Gas mask filters**
- `Gas Mask Filter` entity: replaces a worn-out filter or is kept as a spare (up to 3). A spare is screwed in automatically, and spares drop on death.

**Compatibility**
- GMod Bombs 5 and JMod gas masks and suits.
- vFire.
- WAC and LVS rotor wash.
- Fire extinguishers.
- Procedural Wall Destruction.
- DrGBase and VJ Base.

**Developers**
- Stable `AetherGas.API` (version 1) with hooks. See `docs/API.md`.
