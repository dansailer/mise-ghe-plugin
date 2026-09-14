local file = require("file")

function PLUGIN:BackendExecEnv(ctx)
    local env_vars = {}
    local bin_path = file.join_path(ctx.install_path, "bin")
    if file.exists(bin_path) then
        table.insert(env_vars, { key = "PATH", value = bin_path })
    end
    table.insert(env_vars, { key = "PATH", value = ctx.install_path })
    return { env_vars = env_vars }
end
