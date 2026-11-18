-- lua/autorun/aether_gas_init.lua
-- Точка входа Aether: Volumetric Smoke & Gas Dynamics.
--
-- Порядок загрузки важен: реестр (константы, ConVar'ы, пространства имён) → пространственная сетка →
-- ядро порталов → серверные модули. Каждый модуль идемпотентен: повторный include (lua refresh при
-- сохранении файла, lua_openscript) сохраняет накопленный кэш коллизий и не дублирует хуки/таймеры,
-- потому что всё состояние живёт в таблицах AetherGas.*, а хуки и таймеры регистрируются под
-- постоянными именами.

AddCSLuaFile()

AetherGas = AetherGas or {}

local SHARED_FILES = {
    "aether_gas/shared/sh_registry.lua",
    "aether_gas/shared/sh_lang.lua",
    "aether_gas/shared/sh_spatial.lua",
    "aether_gas/shared/sh_portals.lua",
    "aether_gas/shared/sh_solver.lua",
    "aether_gas/shared/sh_fire.lua",
    "aether_gas/shared/sh_properties.lua",
    "aether_gas/shared/sh_custom.lua",
    "aether_gas/shared/sh_api.lua",
}

local SERVER_FILES = {
    "aether_gas/server/sv_portals.lua",
    "aether_gas/server/sv_debug.lua",
    "aether_gas/server/sv_network.lua",
    "aether_gas/server/sv_compat.lua",
    "aether_gas/server/sv_devices.lua",
}

local CLIENT_FILES = {
    "aether_gas/client/cl_mesher.lua",
    "aether_gas/client/cl_effects.lua",
    "aether_gas/client/cl_menu.lua",
    "aether_gas/client/cl_gas_editor.lua",
}

if SERVER then
    for i = 1, #SHARED_FILES do AddCSLuaFile(SHARED_FILES[i]) end
    for i = 1, #CLIENT_FILES do AddCSLuaFile(CLIENT_FILES[i]) end
end

for i = 1, #SHARED_FILES do include(SHARED_FILES[i]) end

if SERVER then
    for i = 1, #SERVER_FILES do include(SERVER_FILES[i]) end
else
    for i = 1, #CLIENT_FILES do include(CLIENT_FILES[i]) end
end

MsgC(Color(120, 200, 255), "[Aether] ", color_white,
    "v" .. AetherGas.Version .. " loaded (" .. (SERVER and "server" or "client") .. ")\n")
