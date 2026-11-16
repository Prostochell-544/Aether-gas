# Changelog

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
