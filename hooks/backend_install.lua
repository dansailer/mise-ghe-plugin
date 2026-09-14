local file = require("file")
local archiver = require("archiver")
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
    local releases = ghe.list_releases(api_url, owner, repo, token)
    local release = ghe.find_release(releases, version)
    local asset = ghe.pick_asset(release.assets, options)
    if type(asset.name) ~= "string" or asset.name == "" then
        error("Selected release asset has no name")
    end

    ghe.ensure_dir(install_path)
    ghe.ensure_dir(download_path)

    local archive_path = file.join_path(download_path, asset.name)
    ghe.download_asset(asset, archive_path, token)

    if ghe.is_archive(asset.name) then
        local ok = pcall(archiver.decompress, archive_path, install_path, { strip_components = 1 })
        if not ok then
            archiver.decompress(archive_path, install_path)
        end
    else
        local dest = file.join_path(install_path, ghe.bin_name(options, repo))
        file.move(archive_path, dest)
        ghe.chmod_x(dest)
    end

    return {}
end
