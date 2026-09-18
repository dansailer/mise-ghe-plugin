-- Shared helpers for the ghe backend plugin. Lua 5.1 only.
--
-- The module keeps policy in one place so the list-versions and install hooks
-- resolve URLs, credentials, releases, and assets identically.

local M = {}

-- Name fragments used to match release assets to the target platform.
local OS_NEEDLES = {
    darwin = { "darwin", "macos", "osx", "apple", "mac" },
    linux = { "linux" },
    windows = { "windows", "win", "pc-windows" },
}

local X86_64_NEEDLES = { "x64", "amd64", "x86_64", "x86-64" }
local ARM64_NEEDLES = { "arm64", "aarch64" }
local X86_NEEDLES = { "x86", "i386", "i686", "386" }

-- Keyed by the RUNTIME.archType values mise reports.
local ARCH_NEEDLES = {
    x64 = X86_64_NEEDLES,
    amd64 = X86_64_NEEDLES,
    x86_64 = X86_64_NEEDLES,
    arm64 = ARM64_NEEDLES,
    aarch64 = ARM64_NEEDLES,
    x86 = X86_NEEDLES,
    ["386"] = X86_NEEDLES,
}

-- Suffixes identifying metadata sidecars and extractable archives.
local SIDECAR_SUFFIXES = { ".sha256", ".sha256sum", ".asc", ".sig", ".json", ".sbom" }
local ARCHIVE_SUFFIXES = { ".tar.gz", ".tgz", ".tar.xz", ".tar.bz2", ".zip", ".tar" }

-- Name fragments that mark an asset as unlikely to be the wanted binary.
local PENALIZED_FRAGMENTS = { "debug", "test", "sha256", ".sbom" }

-- Trim optional configuration values before they are validated or compared.
local function trim(s)
    if type(s) ~= "string" then
        return s
    end
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Return a normalized string, or nil for missing/blank values.
local function nonempty(s)
    s = trim(s)
    if type(s) ~= "string" or s == "" then
        return nil
    end
    return s
end

-- Read a string-valued tool option without treating arbitrary values as text.
local function option_string(options, key)
    if type(options) ~= "table" then
        return nil
    end
    return nonempty(options[key])
end

-- Perform literal substring matching; asset patterns are not Lua patterns.
local function contains(haystack, needle)
    return haystack:find(needle, 1, true) ~= nil
end

-- Test a suffix without Lua pattern semantics.
local function ends_with(s, suffix)
    return suffix == "" or s:sub(-#suffix) == suffix
end

-- Test an already lowercased name against a suffix list.
local function any_suffix(name, suffixes)
    for _, suffix in ipairs(suffixes) do
        if ends_with(name, suffix) then
            return true
        end
    end
    return false
end

-- API and download URLs are deliberately restricted to HTTPS.
local function is_https(url)
    return type(url) == "string" and url:sub(1, 8):lower() == "https://"
end

-- Sidecar files are metadata, not installable release binaries.
local function is_sidecar(name)
    return any_suffix(name:lower(), SIDECAR_SUFFIXES)
end

-- Escape an owner or repository component for a URL path.
local function path_escape(s)
    return (s:gsub("([^%w%-%._])", function(c)
        return string.format("%%%02X", string.byte(c))
    end))
end

-- Keep remote error messages bounded so an API response cannot flood output.
local function truncate(s, max_len)
    if type(s) ~= "string" then
        return ""
    end
    if #s <= max_len then
        return s
    end
    return s:sub(1, max_len) .. "..."
end

-- Render a bounded, comma-separated list of candidates for an error message.
local function list_for_error(items, max)
    local n = #items
    if n == 0 then
        return "(none)"
    end
    local shown = (max and n > max) and max or n
    local parts = {}
    for i = 1, shown do
        parts[i] = items[i]
    end
    local listed = table.concat(parts, ", ")
    if n > shown then
        listed = listed .. ", ..."
    end
    return listed
end

-- Return the first usable environment variable in a fallback chain.
local function env_first(names)
    for _, name in ipairs(names) do
        local value = nonempty(os.getenv(name))
        if value then
            return value
        end
    end
    return nil
end

-- RUNTIME.pluginDirPath is the stable mise-provided path available to hooks.
local function plugin_dir_path()
    local path = RUNTIME and RUNTIME.pluginDirPath
    if type(path) ~= "string" or path == "" then
        return nil
    end
    return path
end

-- Return one parent path component, or nil when there is no useful parent.
local function parent_dir(path)
    local parent = path:gsub("[/\\][^/\\]+$", "")
    if parent == "" then
        return nil
    end
    return parent
end

-- Find a standard gh configuration directory when mise omitted HOME from the
-- hook environment. pluginDirPath is <MISE_DATA_DIR>/plugins/ghe; two hops up
-- reach <MISE_DATA_DIR>, and one more reaches the home directory where all
-- standard gh config locations live.
local function gh_config_dir_from_plugin_path()
    local path = plugin_dir_path()
    if not path then return nil end
    local file = require("file")

    -- Walk up a few ancestors looking for standard gh config locations.
    -- This avoids assuming a fixed relationship between <MISE_DATA_DIR> and $HOME.
    local current = path
    for _ = 1, 8 do
        current = parent_dir(current)
        if not current then
            return nil
        end
        for _, candidate in ipairs({
            file.join_path(current, ".config", "gh"),
            file.join_path(current, "AppData", "Roaming", "GitHub CLI"),
            file.join_path(current, "Library", "Application Support", "gh"),
        }) do
            if file.exists(file.join_path(candidate, "hosts.yml")) then
                return candidate
            end
        end
    end
    return nil
end

-- Find mise's gh shim so a globally installed github-cli can be used by a hook.
-- pluginDirPath is <MISE_DATA_DIR>/plugins/ghe; two hops up reach <MISE_DATA_DIR>.
local function mise_shims_from_plugin_path()
    local path = plugin_dir_path()
    if not path then return nil end
    local file = require("file")

    -- plugins/ghe -> plugins -> <MISE_DATA_DIR>
    path = parent_dir(parent_dir(path))
    if not path then return nil end

    local shims = file.join_path(path, "shims")
    if file.exists(file.join_path(shims, "gh")) then
        return shims
    end
    return nil
end

-- Report whether the target runtime is Windows.
local function is_windows()
    return (RUNTIME.osType or ""):lower() == "windows"
end

--- Resolve and validate the GHE API root.
-- A tool option overrides MISE_GHE_API_URL, which overrides GHE_API_URL.
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
    if not is_https(url) then
        error(
            "GitHub Enterprise API URL must be HTTPS. Set tool option api_url, or MISE_GHE_API_URL (or GHE_API_URL). Example: https://github.mycompany.com/api/v3"
        )
    end
    if url:find("@", 1, true) then
        error("GitHub Enterprise API URL must not include userinfo (user:password@). Use a token env var instead.")
    end
    return url
end

--- Extract the hostname from an API or asset URL.
function M.host_from_api_url(api_url)
    if type(api_url) ~= "string" then
        return nil
    end
    local host = api_url:gsub("^https?://", ""):gsub("^[^/]*@", ""):gsub("/.*$", ""):gsub(":.*$", "")
    return nonempty(host:lower())
end

--- Return host candidates used for gh authentication and same-host checks.
-- An api.* hostname also permits the corresponding hostname without api.*.
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

--- Check whether two URL hosts resolve to the same accepted GHE host.
-- This prevents authenticated asset downloads from following a different host.
function M.same_http_host(url, api_url)
    local api_hosts = M.gh_hosts_for_api_url(api_url)
    for _, host in ipairs(M.gh_hosts_for_api_url(url)) do
        for _, api_host in ipairs(api_hosts) do
            if host == api_host then
                return true
            end
        end
    end
    return false
end

-- Ask gh for a token without interpolating the host into shell source.
-- The explicit environment repairs the sanitized environment used by mise hooks.
local function gh_auth_token(host)
    local cmd = require("cmd")
    -- Host goes through GH_HOST so it is never interpolated into the shell string.
    local gh_env = {
        GH_HOST = host,
        GH_PROMPT_DISABLED = "1",
        GIT_TERMINAL_PROMPT = "0",
        -- Resolve GH_CONFIG_DIR once: prefer the environment value, fall back to
        -- path discovery so the standard gh login works without any manual config.
        GH_CONFIG_DIR = nonempty(os.getenv("GH_CONFIG_DIR")) or gh_config_dir_from_plugin_path(),
    }
    for _, name in ipairs({ "PATH", "HOME", "USERPROFILE", "XDG_CONFIG_HOME", "APPDATA", "LOCALAPPDATA" }) do
        local value = nonempty(os.getenv(name))
        if value then
            gh_env[name] = value
        end
    end
    -- Backend hooks may not include mise-managed tool paths in PATH.
    local shims = mise_shims_from_plugin_path()
    if shims then
        local sep = is_windows() and ";" or ":"
        if gh_env.PATH and gh_env.PATH ~= "" then
            gh_env.PATH = shims .. sep .. gh_env.PATH
        else
            gh_env.PATH = shims
        end
    end
    local ok, output = pcall(cmd.exec, "gh auth token", { env = gh_env })
    if not ok then
        return nil
    end
    return nonempty(output)
end

--- Try gh authentication for each hostname derived from the API URL.
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

--- Resolve credentials in the documented precedence order.
-- Tool options and GHE-specific variables win before gh and generic tokens.
function M.token(options, api_url)
    return option_string(options, "token")
        or env_first({ "MISE_GITHUB_ENTERPRISE_TOKEN", "MISE_GHE_TOKEN" })
        or M.token_from_gh(api_url)
        or env_first({ "MISE_GITHUB_TOKEN", "GITHUB_TOKEN", "GITHUB_API_TOKEN" })
end

--- Normalize a backend tool name and return its owner and repository.
-- Extra path components are ignored for compatibility with mise tool names.
function M.parse_tool(tool)
    if type(tool) ~= "string" then
        error("Tool name must be owner/repo")
    end
    tool = trim(tool):gsub("^/+", ""):gsub("/+$", "")
    local owner, repo = tool:match("^([^/]+)/([^/]+)")
    if not owner or not repo then
        error("Tool name must be owner/repo, got: " .. tool)
    end
    return owner, repo
end

--- Build common GitHub API headers for JSON requests or asset downloads.
-- Authorization is only added when a credential was successfully resolved.
function M.headers(token, accept)
    local headers = {
        ["User-Agent"] = "mise-ghe-backend",
        ["Accept"] = accept or "application/vnd.github+json",
        ["X-GitHub-Api-Version"] = "2022-11-28",
    }
    if token then
        headers["Authorization"] = "Bearer " .. token
    end
    return headers
end

--- Fetch and decode a JSON API response with useful status-specific errors.
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
        local gh_hint = host and ("gh auth login --hostname " .. host) or "gh auth login"
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

--- Fetch all published releases for a repository, up to ten API pages.
-- The API's release order is preserved for later version ordering decisions.
function M.list_releases(api_url, owner, repo, token)
    local all = {}
    local page = 1
    local owner_esc = path_escape(owner)
    local repo_esc = path_escape(repo)
    while page <= 10 do
        local url = string.format(
            "%s/repos/%s/%s/releases?per_page=100&page=%d",
            api_url,
            owner_esc,
            repo_esc,
            page
        )
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
        for _, rel in ipairs(data) do
            table.insert(all, rel)
        end
        if #data < 100 then
            break
        end
        page = page + 1
    end
    return all
end

--- Remove one conventional leading v from a release tag.
function M.normalize_tag(tag)
    if type(tag) ~= "string" then
        return tag
    end
    return (tag:gsub("^v", ""))
end

-- Match a requested version while accepting either v1.2.3 or 1.2.3.
local function version_matches(field, version)
    if type(field) ~= "string" or field == "" then
        return false
    end
    local nf = M.normalize_tag(field)
    return field == version or nf == version or nf == M.normalize_tag(version)
end

-- Return OS and architecture aliases used by release asset matching.
local function os_arch()
    local os_type = (RUNTIME.osType or ""):lower()
    local arch_type = (RUNTIME.archType or ""):lower()
    return OS_NEEDLES[os_type] or { os_type }, ARCH_NEEDLES[arch_type] or { arch_type }
end

-- Test whether an asset name contains any platform alias.
local function any_needle(name, needles)
    for _, needle in ipairs(needles) do
        if needle ~= "" and contains(name, needle) then
            return true
        end
    end
    return false
end

-- Detect an asset explicitly labeled for an OS other than the current one.
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

-- Score a lowercased asset name for the current OS and architecture.
-- Native, matching, non-debug archives score higher; sidecar-like names score lower.
local function score_asset(name, os_aliases, arch_aliases)
    local score = 0
    if any_needle(name, os_aliases) then
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
    for _, fragment in ipairs(PENALIZED_FRAGMENTS) do
        if contains(name, fragment) then
            score = score - 40
        end
    end
    if any_suffix(name, ARCHIVE_SUFFIXES) then
        score = score + 10
    end
    if any_suffix(name, SIDECAR_SUFFIXES) then
        score = score - 80
    end
    return score
end

--- Select the best release asset for the current platform.
-- An explicit asset_pattern/matching option permits intentionally foreign assets.
function M.pick_asset(assets, options)
    options = options or {}
    local os_aliases, arch_aliases = os_arch()
    local pattern = option_string(options, "asset_pattern") or option_string(options, "matching")
    local names = {}
    local best, best_score = nil, nil
    for _, asset in ipairs(assets or {}) do
        local name = asset.name
        if type(name) == "string" and name ~= "" then
            table.insert(names, name)
            local lower = name:lower()
            if (not is_sidecar(lower)) and (pattern == nil or pattern == "" or contains(lower, pattern)) then
                local score = score_asset(lower, os_aliases, arch_aliases)
                local acceptable = pattern ~= nil
                    or (
                        score > 0
                        and not foreign_os_present(lower, os_aliases)
                        and (any_needle(lower, os_aliases) or any_needle(lower, arch_aliases))
                    )
                if acceptable and (best_score == nil or score > best_score) then
                    best = asset
                    best_score = score
                end
            end
        end
    end
    if not best then
        error("No matching release asset for this platform. Available assets: " .. list_for_error(names))
    end
    return best
end

-- Use tag_name when available and fall back to the release display name.
local function release_tag(rel)
    return nonempty(rel.tag_name) or nonempty(rel.name)
end

--- Find a non-draft release matching a requested version.
-- Matching accepts both the normalized and v-prefixed forms.
function M.find_release(releases, version)
    local available = {}
    for _, rel in ipairs(releases or {}) do
        if rel.draft ~= true then
            local tag = release_tag(rel)
            if tag then
                table.insert(available, M.normalize_tag(tag))
            end
            if version_matches(rel.tag_name, version) or version_matches(rel.name, version) then
                return rel
            end
        end
    end
    error(
        "Unknown version '" .. tostring(version) .. "'. Available: " .. list_for_error(available, 20)
    )
end

--- Convert non-draft releases into unique versions, oldest first.
-- The GHE API returns releases newest-first; iterating in reverse gives oldest-first.
function M.versions_from_releases(releases)
    local seen = {}
    local result = {}
    local list = releases or {}
    for i = #list, 1, -1 do
        local rel = list[i]
        if rel.draft ~= true then
            local tag = release_tag(rel)
            if tag then
                local v = M.normalize_tag(tag)
                if v ~= "" and not seen[v] then
                    seen[v] = true
                    table.insert(result, v)
                end
            end
        end
    end
    return result
end

--- Identify archive formats that the installer knows how to extract.
function M.is_archive(name)
    if type(name) ~= "string" then
        return false
    end
    return any_suffix(name:lower(), ARCHIVE_SUFFIXES)
end

--- Strip path components from an asset name and reject unusable filenames.
function M.safe_filename(name)
    if type(name) ~= "string" then
        return nil
    end
    local base = name:gsub("\\", "/"):match("([^/]*)$")
    if base == "" or base == "." or base == ".." then
        return nil
    end
    return base
end

--- Download one release asset after enforcing HTTPS and same-host policy.
-- API asset URLs receive the token; browser URLs never receive it.
function M.download_asset(asset, dest, token, api_url)
    local http = require("http")
    local file = require("file")
    local url = asset.url
    local from_api = type(url) == "string" and url ~= ""
    if not from_api then
        url = asset.browser_download_url
    end
    if type(url) ~= "string" or url == "" then
        error("Release asset has no download URL: " .. tostring(asset.name))
    end
    if not is_https(url) then
        error("Download URL must be HTTPS")
    end
    if not M.same_http_host(url, api_url) then
        error("Download URL host does not match api_url")
    end
    local headers = M.headers(from_api and token or nil, "application/octet-stream")
    local err = http.download_file({ url = url, headers = headers }, dest)
    if err ~= nil then
        error("Download failed: " .. tostring(err))
    end
    if not file.exists(dest) then
        error("Download failed: file was not written")
    end
end

--- Create an installation or download directory without interpolating its path.
function M.ensure_dir(path)
    local file = require("file")
    if file.exists(path) then
        return
    end
    local cmd = require("cmd")
    local command = is_windows() and 'mkdir "%MISE_GHE_DIR%"' or 'mkdir -p "$MISE_GHE_DIR"'
    local ok, err = pcall(cmd.exec, command, { env = { MISE_GHE_DIR = path } })
    if not ok and not file.exists(path) then
        error("Failed to create directory: " .. tostring(err))
    end
end

--- Mark an installed non-Windows binary executable.
function M.chmod_x(path)
    if is_windows() then
        return
    end
    local cmd = require("cmd")
    cmd.exec('chmod +x "$MISE_GHE_BIN"', { env = { MISE_GHE_BIN = path } })
end

--- Resolve and validate the installed binary name for a repository.
-- The bin option is preferred; rename_exe is a deprecated synonym.
function M.bin_name(options, repo)
    local name = option_string(options, "bin")
        or option_string(options, "rename_exe")  -- deprecated: use bin
        or repo
    local safe = M.safe_filename(name)
    if not safe then
        error("Invalid binary name")
    end
    return safe
end

return M
