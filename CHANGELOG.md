# Changelog

## 0.12.0 — visual update (2026-11-20)

### Smoke
- **Ultra smoke (on by default):** clouds are drawn with Aether's own shaders (vs_2_0 + ps_2_b, built from HLSL by `tools/build_shaders.py`). Puffs fade out per pixel where they meet floors and walls, using the frame depth, so there is no hard line where a sprite cuts through geometry. Switched off automatically on graphics cards without DirectX 9 shaders. Q → Utilities → Aether Gas → Ultra smoke, or `aether_ultra 0/1`; `aether_ultra_fade` sets the soft contact width.
- **Clouds move (Ultra):** puffs slowly billow along a coherent wind-like field, and drift along the gas's own movement: smoke rises from a fire, gas pours through doors and down stairs, still gas stays still. Everything runs on the GPU with no extra mesh rebuilds; `aether_ultra_motion` sets the strength (0 = still).
- 16 different puffs (was 4) with inner relief and ragged edges, near-continuous rotation — no repeating pattern.
- Render sub-grid: every cell draws four puffs at sub-grid points with the gas density interpolated from its neighbours, plus random jitter. Cloud edges are smooth and rounded instead of blocky, as if the voxels were half the size, at no simulation cost.
- Clouds read as volumes: the top of every puff is lit and the bottom darker, gas above a cell shades it (bright on top, dark inside and underneath), cells inside a cloud are darker, and the lit side of dense coloured smoke turns pale (red → pink).
- Gas lies on the ground: puffs sit right on the floor, cells near the floor get a dense flat puff on the surface, and heavy gases (chlorine, CO2…) are flattened into a low blanket. The real ground under every cell (slopes, displacements) is found with one cached trace.
- Coloured dynamic light: flares, fire, explosions, flashlights and other addons' dynamic lights tint the smoke.
- Level of detail: cells deep inside a cloud and distant chunks draw two larger puffs instead of four — about half the translucent overdraw where it cannot be seen.

### Fire smoke
- Hot smoke near the fire is lighter and greyer and glows orange from the flames below; it darkens to black as it cools and rises.
- No more flickering at the fire: smoke flows from a steady source above each burning spot instead of a burst every half second.

### Items
- **Looks for every item**, all procedural, worn and stencilled (Soviet / NATO style):
  - **Gas cylinders** in five looks: Soviet (GOST 949-73 colours, Cyrillic stencil, chips down to red primer, rust), NATO (US/NATO marking: grey with green bands for agents, red for riot control, olive drab with EN 1089-3 shoulders for supply gases), modern (industrial, GHS label), classic (before 0.12) and unmarked (rusty). Each gas has its own cylinder model with exactly these five skins. Brass valve, red handwheel.
  - **Gas grenades:** Soviet (olive RDG-style can), NATO (M18-style) and classic.
  - **Signal flares:** Soviet (kraft cardboard tube, paper bands, stamp), NATO and classic.
  - **Antidotes:** Soviet and NATO. **Fans, blowers and duct vents:** Soviet, NATO and classic; a duct's exhaust vent takes the look of its intake.
  - Look of new items: Q → Utilities → Aether Gas → Look of new items (`aether_cylinder_style` 0 random … 5 unmarked). One item: C menu → right-click → Look.
  - **Look of grenades and flares in hand:** weapons can't be restyled in the C menu, so each player picks it in Q → Utilities → Aether Gas (`aether_look_grenade`, `aether_look_flare`). A thrown grenade or flare keeps the look.
- **Gas mask is a detailed GP-7** — ["GP7 Gasmask"](https://sketchfab.com/3d-models/gp7-gasmask-844e2d7c0229413281abcf2cf1b99e66) by Shadoff (CC BY 4.0), adapted for Source: normal map, gloss, tinted lens glass, simplified to 21k triangles. The spare filter uses the same GP-7K canister.
- The worn gas mask fits different player models: scaled to the head hitbox and falls back to the head bone without an "eyes" attachment; size and offset fine-tuning in Q → Utilities → Aether Gas.
- **Hazmat suit** comes as a Soviet OZK kit: a closed, painted wooden army crate with stencils, steel corners and rope handles.
- **Gas analyzer** rebuilt as a rugged olive-drab field instrument: screen in a raised bezel, toggles, threshold knob, analog dial, rubber corner guards, sampling probe.
- **Gas sprayer** is an aerosol can on a pistol grip (like a bear-spray launcher), still tinted in the colour of the selected gas.
- **Propane tank** in the Soviet household style: red enamel, «ПРОПАН» stencil, brass valve.
- **Signal flares in the weapons menu:** five flares, one per colour, like the gas grenades. Flares jet smoke from the tip in a narrow cone that widens into billows.
- Normal maps, Phong highlights and environment reflections masked to bare metal and brass on cylinders, grenades, flares and other items.

### Antidotes (new)
Spawn menu → Aether Gas, E to use on yourself:
- **Atropine autoinjector** — sarin: removes half of the dose, clears the rest 4× faster and cuts harm and convulsions to a third for 3 minutes. Can be injected in advance.
- **Decontamination kit (IPP-8)** — removes skin and clothing contamination (mustard gas, sarin).
- **Eye wash** — tear gas and ammonia: tears and burning pass quickly.
- **Oxygen can** — carbon monoxide, CO2, nitrogen: hypoxia eases.
- Mustard gas has no antidote, as in reality: only the mask, the suit and the decontamination kit help.
- API: `AetherGas.API.ApplyAntidote(ent, kind)`, `API.RegisterAntidote(kind, def)`; hook `AetherGas.Antidote(ent, kind)` — return false to block.

### Other
- Download about the same size despite all the new textures (43 → 40 MB): the GP-7 mesh simplified 49k → 21k triangles, screen overlays and the smoke atlas DXT5-compressed, spawn icons 256 px, unused DX8/software model variants dropped.
- Antidote sounds fade out after about a second (the oxygen and eye-wash sounds used to loop forever).
- Tools: `tools/export_props.py` and `tools/blender_scene.py` build a Blender showcase of all props and the Workshop cover renders.

## 0.11.1 — several intakes into one exhaust

- **Several intake vents into one exhaust.** With the Gas Duct tool, click an existing exhaust vent as the second point to join it. E on the exhaust switches all its intakes; right-click on an intake disconnects only that one.

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
