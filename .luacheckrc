-- Luanti mods run on Lua 5.1 with an engine-provided global table.
std = "lua51"
max_line_length = 100

read_globals = {
    "core", "minetest", "vector", "VoxelManip", "VoxelArea",
    "ItemStack", "PseudoRandom", "PerlinNoise", "dump", "dump2",
}

globals = { "luantibot" }

ignore = { "212/self" }

-- Busted injects its DSL as globals into spec files.
files["mods/luantibot/spec"] = {
    read_globals = {
        "describe", "it", "before_each", "after_each",
        "setup", "teardown", "assert", "spy", "stub", "mock",
    },
}
