-- Shared helpers for the ghe backend plugin. Lua 5.1 only.

local M = {}

local OS_NEEDLES = {
    darwin = { "darwin", "macos", "osx", "apple", "mac" },
    linux = { "linux" },
    windows = { "windows", "win", "pc-windows" },
}

local function trim(s)
    if type(s) ~= "string" then
        return s
    end
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function nonempty(s)
    s = trim(s)
    if type(s) ~= "string" or s == "" then
        return nil
    end
    return s
end

local function option_string(options, key)
    if type(options) ~= "table" then
        return nil
    end
    return nonempty(options[key])
end

local function contains(haystack, needle)
    return haystack:find(needle, 1, true) ~= nil
end

local function ends_with(s, suffix)
    return suffix == "" or s:sub(-#suffix) == suffix
end

local function path_escape(s)
    return (s:gsub("([^%w%-%._])", function(c)
        return string.format("%%%02X", string.byte(c))
    end))
end

local function truncate(s, max_len)
    if type(s) ~= "string" then
        return ""
    end
    if #s <= max_len then
        return s
    end
    return s:sub(1, max_len) .. "..."
end

local function env_first(names)
    for _, name in ipairs(names) do
        local value = nonempty(os.getenv(name))
        if value then
            return value
        end
    end
    return nil
end

function M.is_windows()
    return (RUNTIME.osType or ""):lower() == "windows"
end

function M.api_url(options)
    local url = option_string(options, "api_url")
        or env_first({ "MISE_GHE_API_URL", "GHE_API_URL" })
    if url then
        url = url:gsub("/+$", "")
    end
    if not url or url == "" then
        error(
            "GitHub Enterprise API URL is not set. Set tool option api_url, or environment variable MISE_GHE_API_URL (or GHE_API_URL). Example: https://github.mycompany.com/api/v3"
        )
    end
    return url
end

function M.host_from_api_url(api_url)
    if type(api_url) ~= "string" then
        return nil
    end
    local host = api_url:gsub("^https?://", "")
    local at = host:find("@", 1, true)
    if at then
        host = host:sub(at + 1)
    end
    host = host:gsub("/.*$", "")
    local colon = host:find(":", 1, true)
    if colon then
        host = host:sub(1, colon - 1)
    end
    host = trim(host):lower()
    if host == "" then
        return nil
    end
    return host
end

function M.gh_hosts_for_api_url(api_url)
    local host = M.host_from_api_url(api_url)
    if not host then
        return {}
    end
    local hosts = { host }
    if host:sub(1, 4) == "api." then
        local stripped = host:sub(5)
        if stripped ~= "" then
            table.insert(hosts, stripped)
        end
    end
    return hosts
end

local function gh_auth_token(host)
    local cmd = require("cmd")
    -- Host goes through GH_HOST so it is never interpolated into the shell string.
    local ok, output = pcall(cmd.exec, "gh auth token", {
        env = { GH_HOST = host },
    })
    if not ok then
        return nil
    end
    return nonempty(output)
end

function M.token_from_gh(api_url)
    local hosts = M.gh_hosts_for_api_url(api_url)
    for _, host in ipairs(hosts) do
        local token = gh_auth_token(host)
        if token then
            return token
        end
    end
    return nil
end

function M.token(options, api_url)
    return option_string(options, "token")
        or env_first({
            "MISE_GITHUB_ENTERPRISE_TOKEN",
            "MISE_GHE_TOKEN",
            "MISE_GITHUB_TOKEN",
            "GITHUB_TOKEN",
            "GITHUB_API_TOKEN",
        })
        or M.token_from_gh(api_url)
end

function M.parse_tool(tool)
    if type(tool) ~= "string" then
        error("Tool name must be owner/repo")
    end
    tool = trim(tool)
    tool = tool:gsub("^/+", ""):gsub("/+$", "")
    local slash = tool:find("/", 1, true)
    if not slash then
        error("Tool name must be owner/repo, got: " .. tool)
    end
    local owner = tool:sub(1, slash - 1)
    local rest = tool:sub(slash + 1)
    local slash2 = rest:find("/", 1, true)
    local repo
    if slash2 then
        repo = rest:sub(1, slash2 - 1)
    else
        repo = rest
    end
    if owner == "" or repo == "" then
        error("Tool name must be owner/repo, got: " .. tool)
    end
    return owner, repo
end

function M.headers(token)
    local headers = {
        ["User-Agent"] = "mise-ghe-backend",
        ["Accept"] = "application/vnd.github+json",
        ["X-GitHub-Api-Version"] = "2022-11-28",
    }
    if token then
        headers["Authorization"] = "Bearer " .. token
    end
    return headers
end

function M.get_json(url, token)
    local http = require("http")
    local json = require("json")
    local resp, err = http.get({
        url = url,
        headers = M.headers(token),
    })
    if err ~= nil then
        error("HTTP request failed: " .. tostring(err))
    end
    if not resp then
        error("HTTP request failed: empty response from " .. url)
    end
    local status = resp.status_code
    if status == 401 or status == 403 then
        local hosts = M.gh_hosts_for_api_url(url)
        local host = hosts[#hosts]
        local gh_hint = "gh auth login"
        if host then
            gh_hint = "gh auth login --hostname " .. host
        end
        error(
            "GitHub Enterprise API returned "
                .. tostring(status)
                .. " (unauthorized/forbidden). Set MISE_GITHUB_ENTERPRISE_TOKEN, MISE_GHE_TOKEN, or GITHUB_TOKEN with Contents: read for private release assets, or authenticate with gh ("
                .. gh_hint
                .. ")."
        )
    end
    if status == 404 then
        error(
            "GitHub Enterprise API returned 404 for "
                .. url
                .. ". Check org/repo and api_url (tool option api_url, MISE_GHE_API_URL, or GHE_API_URL)."
        )
    end
    if status < 200 or status >= 300 then
        error(
            "GitHub Enterprise API returned "
                .. tostring(status)
                .. ": "
                .. truncate(resp.body, 500)
        )
    end
    local ok, data = pcall(json.decode, resp.body or "")
    if not ok then
        error("Failed to parse JSON from " .. url)
    end
    return data
end

function M.list_releases(api_url, owner, repo, token)
    local all = {}
    local page = 1
    local owner_esc = path_escape(owner)
    local repo_esc = path_escape(repo)
    while page <= 10 do
        local url = api_url
            .. "/repos/"
            .. owner_esc
            .. "/"
            .. repo_esc
            .. "/releases?per_page=100&page="
            .. tostring(page)
        local data = M.get_json(url, token)
        if type(data) ~= "table" then
            error("Unexpected JSON listing releases for " .. owner .. "/" .. repo)
        end
        if data.message and data[1] == nil then
            error(
                "GitHub Enterprise API error listing releases for "
                    .. owner
                    .. "/"
                    .. repo
                    .. ": "
                    .. tostring(data.message)
            )
        end
        local count = 0
        for _, rel in ipairs(data) do
            table.insert(all, rel)
            count = count + 1
        end
        if count < 100 then
            break
        end
        page = page + 1
    end
    return all
end

function M.normalize_tag(tag)
    if type(tag) ~= "string" then
        return tag
    end
    return (tag:gsub("^v", ""))
end

local function version_matches(field, version)
    if type(field) ~= "string" or field == "" then
        return false
    end
    if field == version then
        return true
    end
    local nf = M.normalize_tag(field)
    local nv = M.normalize_tag(version)
    return nf == version or nf == nv
end

function M.os_arch()
    local os_type = (RUNTIME.osType or ""):lower()
    local arch_type = (RUNTIME.archType or ""):lower()

    local os_aliases = OS_NEEDLES[os_type]
    if not os_aliases then
        os_aliases = { os_type }
    end

    local arch_aliases
    if arch_type == "x64" or arch_type == "amd64" or arch_type == "x86_64" then
        arch_aliases = { "x64", "amd64", "x86_64", "x86-64" }
    elseif arch_type == "arm64" or arch_type == "aarch64" then
        arch_aliases = { "arm64", "aarch64" }
    elseif arch_type == "x86" or arch_type == "386" then
        arch_aliases = { "x86", "i386", "i686", "386" }
    else
        arch_aliases = { arch_type }
    end

    return os_aliases, arch_aliases
end

local function any_needle(name, needles)
    for _, needle in ipairs(needles) do
        if needle ~= "" and contains(name, needle) then
            return true
        end
    end
    return false
end

local function foreign_os_present(name, os_aliases)
    local current = {}
    for _, needle in ipairs(os_aliases) do
        current[needle] = true
    end
    for _, group in pairs(OS_NEEDLES) do
        for _, needle in ipairs(group) do
            if not current[needle] and contains(name, needle) then
                return true
            end
        end
    end
    return false
end

function M.score_asset(name, os_aliases, arch_aliases)
    name = name:lower()
    local score = 0
    local os_ok = any_needle(name, os_aliases)
    if os_ok then
        score = score + 100
    elseif foreign_os_present(name, os_aliases) then
        score = score - 50
    end
    if any_needle(name, arch_aliases) then
        score = score + 50
    end
    if contains(name, "musl") then
        score = score - 5
    end
    if contains(name, "debug") then
        score = score - 40
    end
    if contains(name, "test") then
        score = score - 40
    end
    if contains(name, "sha256") then
        score = score - 40
    end
    if contains(name, ".sbom") then
        score = score - 40
    end
    if ends_with(name, ".tar.gz") or ends_with(name, ".tgz") or ends_with(name, ".zip") or ends_with(name, ".tar.xz") then
        score = score + 10
    end
    if ends_with(name, ".sha256") or ends_with(name, ".asc") or ends_with(name, ".sig") or ends_with(name, ".json") then
        score = score - 80
    end
    return score
end

function M.asset_name_matches(name, pattern)
    if pattern == nil or pattern == "" then
        return true
    end
    if name:find(pattern, 1, true) then
        return true
    end
    local ok, start = pcall(function()
        return name:find(pattern)
    end)
    return ok and start ~= nil
end

function M.pick_asset(assets, options)
    options = options or {}
    local os_aliases, arch_aliases = M.os_arch()
    local pattern = option_string(options, "asset_pattern") or option_string(options, "matching")
    local names = {}
    local best, best_score = nil, nil
    for _, asset in ipairs(assets or {}) do
        local name = asset.name
        if type(name) == "string" and name ~= "" then
            table.insert(names, name)
            if M.asset_name_matches(name, pattern) then
                local score = M.score_asset(name, os_aliases, arch_aliases)
                if best_score == nil or score > best_score then
                    best = asset
                    best_score = score
                end
            end
        end
    end
    if not best then
        local listed = table.concat(names, ", ")
        if listed == "" then
            listed = "(none)"
        end
        error("No matching release asset for this platform. Available assets: " .. listed)
    end
    return best
end

function M.find_release(releases, version)
    local available = {}
    for _, rel in ipairs(releases or {}) do
        if rel.draft ~= true then
            local tag = rel.tag_name
            if type(tag) ~= "string" or tag == "" then
                tag = rel.name
            end
            if type(tag) == "string" and tag ~= "" then
                table.insert(available, M.normalize_tag(tag))
            end
            if version_matches(rel.tag_name, version) or version_matches(rel.name, version) then
                return rel
            end
        end
    end
    local n = #available
    local show = n
    if show > 20 then
        show = 20
    end
    local parts = {}
    for i = 1, show do
        parts[i] = available[i]
    end
    local listed = table.concat(parts, ", ")
    if listed == "" then
        listed = "(none)"
    elseif n > 20 then
        listed = listed .. ", ..."
    end
    error("Unknown version '" .. tostring(version) .. "'. Available: " .. listed)
end

function M.versions_from_releases(releases)
    local seen = {}
    local newest_first = {}
    for _, rel in ipairs(releases or {}) do
        if rel.draft ~= true then
            local tag = rel.tag_name
            if type(tag) ~= "string" or tag == "" then
                tag = rel.name
            end
            if type(tag) == "string" and tag ~= "" then
                local v = M.normalize_tag(tag)
                if v ~= "" and not seen[v] then
                    seen[v] = true
                    table.insert(newest_first, v)
                end
            end
        end
    end
    local oldest_first = {}
    for i = #newest_first, 1, -1 do
        table.insert(oldest_first, newest_first[i])
    end
    return oldest_first
end

function M.is_archive(name)
    if type(name) ~= "string" then
        return false
    end
    local n = name:lower()
    return ends_with(n, ".tar.gz")
        or ends_with(n, ".tgz")
        or ends_with(n, ".tar.xz")
        or ends_with(n, ".tar.bz2")
        or ends_with(n, ".zip")
        or ends_with(n, ".tar")
end

function M.download_asset(asset, dest, token)
    local http = require("http")
    local file = require("file")
    local url = asset.url
    if type(url) ~= "string" or url == "" then
        url = asset.browser_download_url
    end
    if type(url) ~= "string" or url == "" then
        error("Release asset has no download URL: " .. tostring(asset.name))
    end
    local headers = M.headers(token)
    headers["Accept"] = "application/octet-stream"
    local err = http.download_file({
        url = url,
        headers = headers,
    }, dest)
    if err ~= nil then
        error("Download failed: " .. tostring(err))
    end
    if not file.exists(dest) then
        error("Download failed: file was not written")
    end
end

function M.ensure_dir(path)
    local file = require("file")
    if file.exists(path) then
        return
    end
    local cmd = require("cmd")
    local command
    if M.is_windows() then
        command = 'mkdir "%MISE_GHE_DIR%"'
    else
        command = 'mkdir -p "$MISE_GHE_DIR"'
    end
    local ok, err = pcall(cmd.exec, command, { env = { MISE_GHE_DIR = path } })
    if not ok and not file.exists(path) then
        error("Failed to create directory: " .. tostring(err))
    end
end

function M.chmod_x(path)
    if M.is_windows() then
        return
    end
    local cmd = require("cmd")
    cmd.exec('chmod +x "$MISE_GHE_BIN"', { env = { MISE_GHE_BIN = path } })
end

function M.bin_name(options, repo)
    return option_string(options, "bin") or option_string(options, "rename_exe") or repo
end

return M
