-- Shared helpers for the ghe backend plugin. Lua 5.1 only.
--
-- The module keeps policy in one place so the list-versions and install hooks
-- resolve URLs, credentials, releases, and assets identically.

local M = {}

-- Release asset names are matched by whole tokens (see name_tokens), never by
-- raw substrings: a substring match lets "win" hit "darwin" or "386" hit a
-- version number. Each OS group lists the tokens that identify it.
local OS_TOKENS = {
    darwin = { "darwin", "macos", "macosx", "osx", "apple", "mac" },
    linux = { "linux" },
    windows = { "windows", "win", "win32", "win64", "exe" },
    -- Recognised only so their assets are rejected as foreign.
    freebsd = { "freebsd" },
    openbsd = { "openbsd" },
    netbsd = { "netbsd" },
    android = { "android" },
    illumos = { "illumos" },
    solaris = { "solaris" },
    aix = { "aix" },
}

-- Architecture groups by token. Groups other than the current one are foreign.
local ARCH_TOKENS = {
    amd64 = { "amd64", "x64", "x86_64" },
    arm64 = { "arm64", "aarch64", "armv8", "arm64e" },
    x86 = { "x86", "386", "i386", "i586", "i686", "ia32" },
    arm = { "arm", "armv5", "armv6", "armv6l", "armv7", "armv7l", "armv7a", "armhf", "armel", "arm32" },
    riscv64 = { "riscv64" },
    ppc64le = { "ppc64le", "ppc64el", "powerpc64le" },
    ppc64 = { "ppc64", "powerpc64", "powerpc" },
    s390x = { "s390x" },
    mips = { "mips", "mipsel", "mipsle", "mipsr6", "mipsr6el" },
    mips64 = { "mips64", "mips64el", "mips64le", "mips64r6", "mips64r6el" },
    loong64 = { "loong64", "loongarch64" },
}

-- Maps RUNTIME.archType values mise reports to an ARCH_TOKENS group.
local RUNTIME_ARCH = {
    x64 = "amd64",
    amd64 = "amd64",
    x86_64 = "amd64",
    arm64 = "arm64",
    aarch64 = "arm64",
    x86 = "x86",
    ["386"] = "x86",
    i386 = "x86",
    i686 = "x86",
    arm = "arm",
    armv7 = "arm",
    riscv64 = "riscv64",
    ppc64le = "ppc64le",
    s390x = "s390x",
    loong64 = "loong64",
}

-- Foreign architectures the OS runs through emulation (Rosetta 2, Windows on
-- Arm x64 emulation). Values are architecture scores, below native (50) and
-- universal (45), so emulation is used only when no better asset exists.
local EMULATED_ARCH = {
    darwin = { arm64 = { amd64 = 20 } },
    windows = { arm64 = { amd64 = 20, x86 = 15 } },
}

-- Tokens marking a binary that runs on every architecture of its OS.
local UNIVERSAL_TOKENS = { "universal", "universal2" }

-- Suffixes identifying metadata sidecars and extractable archives.
local SIDECAR_SUFFIXES = {
    ".sha256", ".sha256sum", ".sha512", ".sha512sum", ".sha1", ".md5", ".b3",
    ".asc", ".sig", ".minisig", ".pem", ".crt", ".cert", ".pub", ".sigstore", ".intoto.jsonl",
    ".json", ".txt", ".sbom", ".spdx", ".cdx",
}
local ARCHIVE_SUFFIXES = { ".tar.gz", ".tgz", ".tar.xz", ".tar.bz2", ".zip", ".tar" }

-- OS installer packages; this plugin cannot install them, so they are never selected.
local PACKAGE_SUFFIXES = {
    ".deb", ".rpm", ".apk", ".pkg", ".dmg", ".msi", ".msix", ".appx", ".snap", ".flatpak", ".nupkg",
}

-- Suffixes removed before tokenizing so "amd64.tar.gz" yields the token "amd64".
local STRIP_SUFFIXES = { ".tar", ".gz", ".tgz", ".xz", ".txz", ".bz2", ".tbz2", ".zst", ".zip", ".7z", ".exe" }

-- Name tokens that mark an asset as unlikely to be the wanted binary.
local PENALIZED_TOKENS = { "debug", "dbg", "test", "tests", "symbols" }

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

-- Sidecar files are metadata, not installable release binaries. Besides the
-- suffix list this catches extension-less checksum files such as SHA256SUMS.
local function is_sidecar(name)
    local lower = name:lower()
    if any_suffix(lower, SIDECAR_SUFFIXES) then
        return true
    end
    local base = lower:match("([^/]*)$")
    return base:match("^sha%d*sums?$") ~= nil
        or base:match("^md5sums?$") ~= nil
        or base:match("checksums?$") ~= nil
end

-- OS installer packages (.deb, .msi, ...) are not installable by this plugin.
local function is_package(name)
    return any_suffix(name:lower(), PACKAGE_SUFFIXES)
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

-- Set while `gh auth token` runs. When gh resolves to mise's shim, the shim
-- re-enters mise, which may call this plugin again to resolve a not-yet-installed
-- ghe tool; that nested call must not invoke gh again or it recurses forever.
local GH_LOOKUP_GUARD = "MISE_GHE_IN_GH_LOOKUP"

-- Ask gh for a token without interpolating the host into shell source.
-- The explicit environment repairs the sanitized environment used by mise hooks.
local function gh_auth_token(host)
    if nonempty(os.getenv(GH_LOOKUP_GUARD)) then
        return nil
    end
    local cmd = require("cmd")
    -- Host goes through GH_HOST so it is never interpolated into the shell string.
    local gh_env = {
        [GH_LOOKUP_GUARD] = "1",
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
    -- Backend hooks may not include mise-managed tool paths in PATH. Append the
    -- shims dir as a last resort only: a real gh already on PATH must win, because
    -- the gh shim is mise itself and re-enters this plugin.
    local shims = mise_shims_from_plugin_path()
    if shims then
        local sep = is_windows() and ";" or ":"
        if gh_env.PATH and gh_env.PATH ~= "" then
            gh_env.PATH = gh_env.PATH .. sep .. shims
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

-- Split a release asset name into a set of lowercased tokens. Spellings that
-- contain separators are normalized first (x86_64 -> amd64, linux64 ->
-- linux amd64), packaging suffixes are dropped, and dotted parts such as
-- "darwin.arm64" are split unless they are purely numeric (version numbers).
function M.name_tokens(name)
    local lower = name:lower()
    local set = {}
    if ends_with(lower, ".exe") then
        set.exe = true
    end
    local stripped = true
    while stripped do
        stripped = false
        for _, suffix in ipairs(STRIP_SUFFIXES) do
            if #lower > #suffix and ends_with(lower, suffix) then
                lower = lower:sub(1, -#suffix - 1)
                stripped = true
                break
            end
        end
    end
    -- %f frontiers keep these to whole words ("darwin64" is not "win64").
    lower = lower
        :gsub("%f[%w]x86[_%-]64%f[%W]", "amd64")
        :gsub("%f[%w]linux64%f[%W]", "linux-amd64")
        :gsub("%f[%w]linux32%f[%W]", "linux-x86")
        :gsub("%f[%w]win64%f[%W]", "windows-amd64")
    for token in lower:gmatch("[%w%.]+") do
        set[token] = true
        if token:find(".", 1, true) then
            for part in token:gmatch("[%w]+") do
                if part:find("%a") then
                    set[part] = true
                end
            end
        end
    end
    return set
end

-- Test whether a token set contains any token from a list.
local function has_token(tokens, list)
    for _, token in ipairs(list) do
        if tokens[token] then
            return true
        end
    end
    return false
end

-- Return the current OS name and architecture group from RUNTIME.
local function platform()
    local os_type = (RUNTIME.osType or ""):lower()
    local arch_type = (RUNTIME.archType or ""):lower()
    return os_type, RUNTIME_ARCH[arch_type] or arch_type
end

-- Classify an asset's OS tokens: "foreign" when any other OS is named,
-- otherwise "native" when the current OS is named, otherwise "none".
local function os_match(tokens, os_type)
    for name, list in pairs(OS_TOKENS) do
        if name ~= os_type and has_token(tokens, list) then
            return "foreign"
        end
    end
    local native = OS_TOKENS[os_type] or { os_type }
    if has_token(tokens, native) then
        return "native"
    end
    return "none"
end

-- Classify an asset's architecture tokens: "native", "universal", "emulated",
-- "foreign", or "none". The second result is the architecture score.
local function arch_match(tokens, os_type, arch_group)
    if has_token(tokens, ARCH_TOKENS[arch_group] or { arch_group }) then
        return "native", 50
    end
    local foreign_group = nil
    for name, list in pairs(ARCH_TOKENS) do
        if name ~= arch_group and has_token(tokens, list) then
            foreign_group = name
            break
        end
    end
    if foreign_group then
        local emulated = EMULATED_ARCH[os_type] and EMULATED_ARCH[os_type][arch_group]
        if emulated and emulated[foreign_group] then
            return "emulated", emulated[foreign_group]
        end
        return "foreign", -100
    end
    if has_token(tokens, UNIVERSAL_TOKENS) or (os_type == "darwin" and tokens.all) then
        return "universal", 45
    end
    return "none", 0
end

local OS_SCORE = { native = 100, none = 0, foreign = -100 }

-- Score an asset name for the current platform. Returns the score and whether
-- the asset is acceptable without an explicit asset_pattern: it must not be
-- labelled for another OS or architecture, and must match the OS or the
-- architecture (natively, universally, or via emulation).
local function score_asset(name, os_type, arch_group)
    local tokens = M.name_tokens(name)
    local os_kind = os_match(tokens, os_type)
    local arch_kind, arch_score = arch_match(tokens, os_type, arch_group)
    local score = OS_SCORE[os_kind] + arch_score
    if tokens.musl then
        score = score - 5
    end
    if os_type == "windows" and tokens.msvc then
        score = score + 3
    end
    if has_token(tokens, PENALIZED_TOKENS) then
        score = score - 40
    end
    if any_suffix(name, ARCHIVE_SUFFIXES) then
        score = score + 10
    end
    local acceptable = os_kind ~= "foreign"
        and arch_kind ~= "foreign"
        and (os_kind == "native" or arch_kind ~= "none")
    return score, acceptable
end

--- Select the best release asset for the current platform.
-- Checksum/signature sidecars and OS packages are never selected. Without an
-- asset_pattern/matching option, assets labelled for another OS or
-- architecture are rejected; an explicit pattern permits them.
function M.pick_asset(assets, options)
    options = options or {}
    local os_type, arch_group = platform()
    local pattern = option_string(options, "asset_pattern") or option_string(options, "matching")
    if pattern ~= nil then
        pattern = pattern:lower()
    end
    local names = {}
    local skipped_package = false
    local best, best_score = nil, nil
    for _, asset in ipairs(assets or {}) do
        local name = asset.name
        if type(name) == "string" and name ~= "" then
            table.insert(names, name)
            local lower = name:lower()
            if pattern == nil or contains(lower, pattern) then
                if is_package(lower) then
                    skipped_package = true
                elseif not is_sidecar(lower) then
                    local score, acceptable = score_asset(lower, os_type, arch_group)
                    if (pattern ~= nil or acceptable) and (best_score == nil or score > best_score) then
                        best = asset
                        best_score = score
                    end
                end
            end
        end
    end
    if not best then
        local msg = "No matching release asset for this platform ("
            .. tostring(RUNTIME.osType)
            .. "/"
            .. tostring(RUNTIME.archType)
            .. "). Available assets: "
            .. list_for_error(names)
        if skipped_package then
            msg = msg .. ". OS packages (.deb, .rpm, .msi, .pkg, ...) cannot be installed by this plugin"
        end
        error(msg)
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
