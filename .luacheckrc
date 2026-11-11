-- luacheck configuration: https://luacheck.readthedocs.io/
std = "lua51"
max_line_length = 120
-- Globals provided by mise's plugin runtime.
read_globals = { "RUNTIME" }
globals = { "PLUGIN" }

files["hooks/"] = {
    -- Hooks are PLUGIN:Method definitions; `self` is part of the signature.
    ignore = { "212/self" },
}

files["test/"] = {
    -- The offline tests stub os.getenv and the global RUNTIME.
    ignore = { "122" },
    globals = { "RUNTIME" },
}
