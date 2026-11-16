# Contributing

Thanks for helping. Aether runs a simulation every tick inside Garry's Mod, so a few rules are strict.

## Hard rules

1. **No allocations in hot loops.** Don't create `Vector()`, `Angle()`, closures or tables inside per-cell or per-tick code. Use the bit-packed voxel keys and the flat Structure-of-Arrays fields (`Spatial.Gas`, `Conc`, `Temp`, `VelX/Y/Z`). Add a new per-voxel field with `Spatial.DeclareField(name, default)`, never a parallel table keyed by voxel.
2. **Time budget.** The solver runs on a `SysTime()` budget (`aether_tick_budget`). Don't add work that ignores it.
3. **Traces.** Collision is baked lazily, one face at a time. Portal re-checks are capped at 16 traces per tick, and the cost of each one is known in advance.
4. **Network.** Never send voxel grids. Send compact events: sources, bullet rays, explosions, puffs, plus compressed chunk snapshots. Every net message must stay below 64 KB.
5. **Rendering.** Use one cached `IMesh` per chunk, with no per-voxel entities or particles. The vertex cap of 65,535 must hold.
6. **Hot reload.** Module state lives in `AetherGas.*` tables (`X = X or {}`). Hooks and timers use fixed names `AetherGas.<Module>.<Purpose>`. Clear shared tables in place (`table.Empty`) and never replace them.
7. **Gas ids are the registration order.** Register from shared code only, in the same order on both realms.

## Before you open a pull request

```
python -I tools/luacheck51.py --strict <changed .lua files>
python -I tools/test_bitmath.py
python -I tools/test_solver_physics.py
```

If you change `StepCell` in `sh_solver.lua`, update its Python port in `tools/test_solver_physics.py` in the same pull request.

If you use a GMod global the checker does not know, add it to `GMOD_GLOBALS` in `tools/luacheck51.py`.

## Assets

Models, textures and icons are **generated**, never hand-placed. To change them, edit `tools/make_models.py` (geometry and paint) and rebuild:

```
set GMOD_DIR=C:\path\to\GarrysMod
set AETHER_ADDON=C:\path\to\this\repo
python -I tools/make_models.py            # everything
python -I tools/make_models.py --only gas_vent
```

Two things to know:
- `studiomdl` turns SMD +X into in-game +Y. `write_smd` compensates for this, so model +X equals `ent:GetForward()` in game.
- The material named in the SMD must be the first row of `$texturegroup`, or skins won't swap.

Use only content shipped with base GMod/HL2 or generated into `materials/aether/`.

## License

By sending a pull request you agree that your contribution is published under the project license, [CC BY-NC-SA 4.0](LICENSE).

## Style

Comments in the Lua code are in Russian. Keep new comments short and about the maths or the memory layout. Overlay and HUD strings stay ASCII, because the Source debug fonts may not have Cyrillic.
