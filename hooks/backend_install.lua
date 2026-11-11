local file = require("file")
local ghe = require("ghe")

function PLUGIN:BackendInstall(ctx)
    local options = ctx.options or {}
    local version = ctx.version
    local install_path = ctx.install_path
    local download_path = ctx.download_path
    if type(version) ~= "string" or version == "" then
        error("Version cannot be empty")
    end
    if type(install_path) ~= "string" or install_path == "" then
        error("Install path cannot be empty")
    end
    if type(download_path) ~= "string" or download_path == "" then
        error("Download path cannot be empty")
    end

    local owner, repo = ghe.parse_tool(ctx.tool)
    local api_url = ghe.api_url(options)
    local token = ghe.token(options, api_url)
    local release = ghe.get_release(api_url, owner, repo, version, token)
    local verify = ghe.verify_mode(options)
    local asset = ghe.pick_asset(release.assets, options)
    local filename = ghe.safe_filename(asset.name)
    if not filename then
        error("Selected release asset has an unsafe name: " .. tostring(asset.name))
    end

    ghe.ensure_dir(install_path)
    ghe.ensure_dir(download_path)

    local archive_path = file.join_path(download_path, filename)
    ghe.download_asset(asset, archive_path, token, api_url)
    ghe.verify_asset(archive_path, asset, release.assets, verify, download_path, token, api_url)

    ghe.install_asset(archive_path, install_path, options, repo)

    return {}
end
