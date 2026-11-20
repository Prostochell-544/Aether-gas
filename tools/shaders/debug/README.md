# Диагностика шейдеров (не входит в аддон)

Проверка пути «свой шейдер» в GMod, по которой подбирался режим «Ультра» (2026-11-20).

- Собрать: `python -I tools/build_shaders.py` не трогает эту папку; вручную — скопировать нужные `.hlsl` в
  `tools/shaders/`, собрать, затем положить `cl_shader_debug.lua` в `lua/aether_gas/client/` и подключить в
  `aether_gas_init.lua` (CLIENT_FILES).
- Команда: `aether_shader_test <0 глубина|1 квад|2 пурпурный|3 штатный|4 свой VS c4|5 свой VS c8> [масштаб] [20b|30]`.
- Итог проверки: ps_2_b работает, ps_3_0 со стандартным VS нет; стандартный VS не передаёт COLOR0; свой vs_2_0
  с cModelViewProj (c4) и cViewProj (c8) работает; глубина сцены — в альфе `_rt_ResolvedFullFrameDepth`,
  диапазон ≈ 192 юнита.
