-- Optional offline checks for lib/ghe.lua. No network.
--   lua test/ghe_check.lua

local script = arg and arg[0] or "./test/ghe_check.lua"
local dir = script:match("^(.*)[/\\]") or "."
package.path = dir .. "/../lib/?.lua;" .. package.path

RUNTIME = { osType = "linux", archType = "amd64" }

local ghe = require("ghe")

local function assert_eq(got, expected, msg)
    if got ~= expected then
        error((msg or "assert_eq") .. ": expected " .. tostring(expected) .. ", got " .. tostring(got), 2)
    end
end

local function assert_err(fn, needle, msg)
    local ok, err = pcall(fn)
    if ok then
        error((msg or "assert_err") .. ": expected error containing " .. needle, 2)
    end
    if tostring(err):find(needle, 1, true) == nil then
        error((msg or "assert_err") .. ": expected '" .. needle .. "' in " .. tostring(err), 2)
    end
end

assert_eq(ghe.normalize_tag("v1.2.3"), "1.2.3", "strip v")
assert_eq(ghe.normalize_tag("1.2.3-rc.1"), "1.2.3-rc.1", "keep prerelease")
assert_eq(ghe.normalize_tag("release-1.2"), "release-1.2", "keep other prefix")

local owner, repo = ghe.parse_tool("org/repo")
assert_eq(owner, "org", "parse owner")
assert_eq(repo, "repo", "parse repo")
owner, repo = ghe.parse_tool("org/repo/unused")
assert_eq(owner, "org", "parse extra owner")
assert_eq(repo, "repo", "parse extra repo")
assert_err(function()
    ghe.parse_tool("org")
end, "owner/repo", "missing slash")

assert_eq(ghe.api_url({ api_url = "https://ghe.example/api/v3/" }), "https://ghe.example/api/v3", "strip slash")
assert_err(function()
    ghe.api_url({ api_url = "http://ghe.example/api/v3" })
end, "HTTPS", "reject http")
assert_err(function()
    ghe.api_url({ api_url = "https://user:pass@ghe.example/api/v3" })
end, "userinfo", "reject userinfo")
assert_eq(ghe.host_from_api_url("https://github.mycompany.com/api/v3"), "github.mycompany.com", "host")
assert_eq(
    ghe.host_from_api_url("https://user:pass@github.mycompany.com:443/api/v3"),
    "github.mycompany.com",
    "strip userinfo/port"
)
assert_eq(
    ghe.same_http_host("https://ghe.example/api/v3/repos/o/r/releases/assets/1", "https://ghe.example/api/v3"),
    true,
    "same host"
)
assert_eq(ghe.same_http_host("https://evil.example/x", "https://ghe.example/api/v3"), false, "other host")
assert_eq(
    ghe.same_http_host("https://company.ghe.com/o/r/releases/download/v1/x", "https://api.company.ghe.com/api/v3"),
    true,
    "api. prefix overlap"
)
assert_eq(ghe.safe_filename("tool.tar.gz"), "tool.tar.gz", "basename plain")
assert_eq(ghe.safe_filename("../evil"), "evil", "basename parent")
assert_eq(ghe.safe_filename("foo/../../../tmp/x"), "x", "basename traversal")
assert_eq(ghe.safe_filename(".."), nil, "reject ..")
assert_eq(ghe.safe_filename("."), nil, "reject .")
local gh_hosts = ghe.gh_hosts_for_api_url("https://api.company.ghe.com/api/v3")
assert_eq(gh_hosts[1], "api.company.ghe.com", "api host first")
assert_eq(gh_hosts[2], "company.ghe.com", "strip api. prefix")
gh_hosts = ghe.gh_hosts_for_api_url("https://github.mycompany.com/api/v3")
assert_eq(#gh_hosts, 1, "no extra host")
assert_eq(gh_hosts[1], "github.mycompany.com", "ghe host")

local prev_cmd = package.loaded.cmd
package.loaded.cmd = {
    exec = function()
        error("gh should not run when token option is set")
    end,
}
assert_eq(ghe.token({ token = "  abc  " }, "https://ghe.example/api/v3"), "abc", "trim token")
package.loaded.cmd = prev_cmd

local gh_calls = {}
package.loaded.cmd = {
    exec = function(command, opts)
        if command ~= "gh auth token" then
            error("unexpected command: " .. tostring(command))
        end
        if command:find("ghe.example", 1, true) then
            error("host must not be interpolated into the command")
        end
        if opts.env.GH_PROMPT_DISABLED ~= "1" then
            error("GH_PROMPT_DISABLED must be set")
        end
        table.insert(gh_calls, opts.env.GH_HOST)
        if opts.env.GH_HOST == "ghe.example" then
            return "  ghp_from_gh  \n"
        end
        error("no token for " .. tostring(opts.env.GH_HOST))
    end,
}
assert_eq(ghe.token_from_gh("https://ghe.example/api/v3"), "ghp_from_gh", "gh auth token")
assert_eq(gh_calls[1], "ghe.example", "GH_HOST")
if not os.getenv("MISE_GITHUB_ENTERPRISE_TOKEN") and not os.getenv("MISE_GHE_TOKEN") then
    assert_eq(ghe.token({}, "https://ghe.example/api/v3"), "ghp_from_gh", "gh before generic GITHUB_TOKEN")
end
package.loaded.cmd = {
    exec = function()
        error("gh missing")
    end,
}
assert_eq(ghe.token_from_gh("https://ghe.example/api/v3"), nil, "gh missing is nil")
package.loaded.cmd = prev_cmd

local prev_runtime = RUNTIME
local prev_file = package.loaded.file
local prev_getenv = os.getenv
local seen_gh_env
RUNTIME = {
    osType = "linux",
    archType = "amd64",
    pluginDirPath = "/home/test/.local/share/mise/plugins/ghe",
}
os.getenv = function(name)
    if name == "PATH" then
        return "/usr/bin"
    end
    return nil
end
package.loaded.file = {
    join_path = function(...)
        local parts = {}
        for i = 1, select("#", ...) do
            parts[i] = select(i, ...)
        end
        return table.concat(parts, "/")
    end,
    exists = function(path)
        return path == "/home/test/.config/gh/hosts.yml"
            or path == "/home/test/.local/share/mise/shims/gh"
    end,
}
package.loaded.cmd = {
    exec = function(command, opts)
        if command ~= "gh auth token" then
            error("unexpected command: " .. tostring(command))
        end
        seen_gh_env = opts.env
        return "ghp_from_gh"
    end,
}
assert_eq(ghe.token_from_gh("https://ghe.example/api/v3"), "ghp_from_gh", "gh token with mise env")
assert_eq(seen_gh_env.GH_CONFIG_DIR, "/home/test/.config/gh", "gh config dir")
assert_eq(seen_gh_env.PATH, "/usr/bin:/home/test/.local/share/mise/shims", "mise shims appended after PATH")
assert_eq(seen_gh_env.MISE_GHE_IN_GH_LOOKUP, "1", "recursion guard set for gh")

-- Nested invocation (gh shim re-entering mise -> this plugin) must not run gh.
os.getenv = function(name)
    if name == "MISE_GHE_IN_GH_LOOKUP" then
        return "1"
    end
    return nil
end
package.loaded.cmd = {
    exec = function()
        error("gh must not run inside a nested gh token lookup")
    end,
}
assert_eq(ghe.token_from_gh("https://ghe.example/api/v3"), nil, "recursion guard skips gh")
package.loaded.cmd = prev_cmd
package.loaded.file = prev_file
os.getenv = prev_getenv
RUNTIME = prev_runtime

-- Host-bound environment tokens (#7). gh is unavailable here, so only
-- environment variables can supply a token.
local function token_with_env(env, options, api_url)
    local saved_getenv, saved_cmd, saved_log = os.getenv, package.loaded.cmd, package.loaded.log
    local warnings = {}
    os.getenv = function(name) -- luacheck: ignore 122
        return env[name]
    end
    package.loaded.cmd = {
        exec = function()
            error("gh not installed")
        end,
    }
    package.loaded.log = {
        warn = function(msg)
            table.insert(warnings, msg)
        end,
    }
    local ok, res = pcall(ghe.token, options or {}, api_url)
    os.getenv = saved_getenv -- luacheck: ignore 122
    package.loaded.cmd, package.loaded.log = saved_cmd, saved_log
    if not ok then
        error(res, 0)
    end
    return res, warnings
end

local A_URL = "https://ghe.a.example/api/v3"
local B_URL = "https://ghe.b.example/api/v3"
local env_a = { MISE_GHE_API_URL = A_URL, MISE_GHE_TOKEN = "tok-a" }
assert_eq(token_with_env(env_a, {}, A_URL), "tok-a", "GHE token sent to configured host")
local withheld, warnings = token_with_env(env_a, {}, B_URL)
assert_eq(withheld, nil, "GHE token not sent to another api_url host")
assert_eq(#warnings, 1, "withheld token is reported")
assert_eq(warnings[1]:find("tok-a", 1, true), nil, "warning never contains the token")
assert_eq(warnings[1]:find("MISE_GHE_TOKEN_HOSTS", 1, true) ~= nil, true, "warning explains the opt-in")
assert_eq(
    token_with_env({ GHE_API_URL = A_URL, MISE_GITHUB_ENTERPRISE_TOKEN = "tok-e" }, {}, A_URL),
    "tok-e",
    "GHE_API_URL also defines the token host"
)
assert_eq(
    token_with_env({ MISE_GHE_TOKEN = "tok-a" }, {}, A_URL),
    nil,
    "no configured host: GHE token is not sent to a per-tool api_url"
)
assert_eq(
    token_with_env(
        {
            MISE_GHE_API_URL = A_URL,
            MISE_GHE_TOKEN = "tok-a",
            MISE_GHE_TOKEN_HOSTS = "ghe.c.example, ghe.b.example",
        },
        {},
        B_URL
    ),
    "tok-a",
    "MISE_GHE_TOKEN_HOSTS allows another host"
)
assert_eq(
    token_with_env({ MISE_GHE_TOKEN = "tok-a", MISE_GHE_TOKEN_HOSTS = B_URL }, {}, B_URL),
    "tok-a",
    "MISE_GHE_TOKEN_HOSTS accepts URLs"
)
assert_eq(
    token_with_env(
        { MISE_GHE_API_URL = "https://api.acme.ghe.com", MISE_GHE_TOKEN = "tok" },
        {},
        "https://acme.ghe.com/api/v3"
    ),
    "tok",
    "api. host and its bare host are the same GHE host"
)
assert_eq(
    token_with_env({ MISE_GHE_API_URL = A_URL, MISE_GHE_TOKEN = "tok-a" }, {}, "https://api.ghe.a.example/api/v3"),
    nil,
    "a subdomain of the configured host is not trusted"
)
assert_eq(token_with_env(env_a, { token = "opt" }, B_URL), "opt", "explicit token option still wins")

-- Generic GitHub tokens.
local env_generic = { MISE_GHE_API_URL = A_URL, GITHUB_TOKEN = "gh-generic" }
local generic, generic_warnings = token_with_env(env_generic, {}, A_URL)
assert_eq(generic, nil, "GITHUB_TOKEN not sent to a GHE host by default")
assert_eq(#generic_warnings, 1, "withheld GITHUB_TOKEN is reported")
assert_eq(
    token_with_env({ GITHUB_TOKEN = "gh-generic" }, {}, "https://api.github.com"),
    "gh-generic",
    "GITHUB_TOKEN sent to api.github.com"
)
assert_eq(
    token_with_env(
        { MISE_GHE_API_URL = A_URL, GITHUB_TOKEN = "gh-generic", MISE_GHE_ALLOW_GITHUB_TOKEN = "1" },
        {},
        A_URL
    ),
    "gh-generic",
    "MISE_GHE_ALLOW_GITHUB_TOKEN=1 allows GITHUB_TOKEN for the GHE host"
)
assert_eq(
    token_with_env({ MISE_GHE_ALLOW_GITHUB_TOKEN = "1", GITHUB_TOKEN = "gh-generic" }, {}, B_URL),
    nil,
    "the opt-in only covers configured GHE hosts"
)
assert_eq(
    token_with_env({ GITHUB_SERVER_URL = "https://ghe.a.example", GITHUB_TOKEN = "actions" }, {}, A_URL),
    "actions",
    "GitHub Actions on GHES: GITHUB_TOKEN belongs to GITHUB_SERVER_URL"
)
assert_eq(
    token_with_env({ GITHUB_SERVER_URL = "https://github.com", GITHUB_TOKEN = "actions" }, {}, A_URL),
    nil,
    "github.com Actions token not sent to GHE"
)
assert_eq(
    token_with_env({ MISE_GHE_API_URL = A_URL, MISE_GHE_TOKEN = "tok-a", GITHUB_TOKEN = "gh" }, {}, A_URL),
    "tok-a",
    "GHE token preferred over generic"
)

local h = ghe.headers(nil)
assert_eq(h["User-Agent"], "mise-ghe-backend", "ua")
assert_eq(h["Accept"], "application/vnd.github+json", "accept")
assert_eq(h["Authorization"], nil, "no auth")
h = ghe.headers("secret")
assert_eq(h["Authorization"], "Bearer secret", "bearer")
assert_eq(tostring(h["Authorization"]):find("secret", 1, true) ~= nil, true, "header has token internally")

-- score_asset and os_arch are internal; verify their effects via pick_asset
local linux_asset = { name = "tool-linux-amd64.tar.gz",          url = "https://ghe.example/x/1" }
local musl_asset  = { name = "tool-linux-amd64-musl.tar.gz",     url = "https://ghe.example/x/2" }
local win_asset   = { name = "tool-windows-amd64.zip",           url = "https://ghe.example/x/3" }
local sum_asset   = { name = "tool-linux-amd64.tar.gz.sha256",   url = "https://ghe.example/x/4" }
assert_eq(ghe.pick_asset({ linux_asset, musl_asset }, {}).name, "tool-linux-amd64.tar.gz", "prefer gnu over musl")
assert_eq(ghe.pick_asset({ linux_asset, win_asset },  {}).name, "tool-linux-amd64.tar.gz", "prefer native OS")
assert_eq(
    ghe.pick_asset({ linux_asset, sum_asset }, {}).name,
    "tool-linux-amd64.tar.gz",
    "prefer archive over checksum"
)

-- Platform-aware asset selection (#4, #5). pick_asset reads RUNTIME on each call.
local function names_to_assets(text)
    local list = {}
    for name in text:gmatch("%S+") do
        list[#list + 1] = { name = name }
    end
    return list
end

local function pick_on(os_type, arch_type, assets, opts)
    local saved = RUNTIME
    RUNTIME = { osType = os_type, archType = arch_type }
    local ok, res = pcall(ghe.pick_asset, assets, opts or {})
    RUNTIME = saved
    if not ok then
        error(res, 0)
    end
    return res.name
end

local RIPGREP = names_to_assets([[
ripgrep-14.1.1-aarch64-apple-darwin.tar.gz ripgrep-14.1.1-aarch64-apple-darwin.tar.gz.sha256
ripgrep-14.1.1-aarch64-unknown-linux-gnu.tar.gz ripgrep-14.1.1-aarch64-unknown-linux-gnu.tar.gz.sha256
ripgrep-14.1.1-armv7-unknown-linux-gnueabihf.tar.gz ripgrep-14.1.1-armv7-unknown-linux-musleabi.tar.gz
ripgrep-14.1.1-i686-pc-windows-msvc.zip ripgrep-14.1.1-i686-unknown-linux-gnu.tar.gz
ripgrep-14.1.1-powerpc64-unknown-linux-gnu.tar.gz ripgrep-14.1.1-s390x-unknown-linux-gnu.tar.gz
ripgrep-14.1.1-x86_64-apple-darwin.tar.gz ripgrep-14.1.1-x86_64-pc-windows-gnu.zip
ripgrep-14.1.1-x86_64-pc-windows-msvc.zip ripgrep-14.1.1-x86_64-unknown-linux-musl.tar.gz
ripgrep-14.1.1-x86_64-unknown-linux-musl.tar.gz.sha256 ripgrep_14.1.1-1_amd64.deb ripgrep_14.1.1-1_amd64.deb.sha256
]])
local GH = names_to_assets([[
gh_2.63.0_checksums.txt gh_2.63.0_linux_386.deb gh_2.63.0_linux_386.rpm gh_2.63.0_linux_386.tar.gz
gh_2.63.0_linux_amd64.deb gh_2.63.0_linux_amd64.rpm gh_2.63.0_linux_amd64.tar.gz gh_2.63.0_linux_arm64.deb
gh_2.63.0_linux_arm64.rpm gh_2.63.0_linux_arm64.tar.gz gh_2.63.0_linux_armv6.deb gh_2.63.0_linux_armv6.rpm
gh_2.63.0_linux_armv6.tar.gz gh_2.63.0_macOS_amd64.zip gh_2.63.0_macOS_arm64.zip gh_2.63.0_macOS_universal.pkg
gh_2.63.0_windows_386.msi gh_2.63.0_windows_386.zip gh_2.63.0_windows_amd64.msi gh_2.63.0_windows_amd64.zip
gh_2.63.0_windows_arm64.zip
]])
local JQ = names_to_assets([[
jq-1.7.1.tar.gz jq-1.7.1.zip jq-linux-amd64 jq-linux-arm64 jq-linux-armel jq-linux-armhf jq-linux-i386
jq-linux-mips jq-linux-mips64 jq-linux-mips64el jq-linux-mips64r6 jq-linux-mips64r6el jq-linux-mipsel
jq-linux-mipsr6 jq-linux-mipsr6el jq-linux-powerpc jq-linux-ppc64el jq-linux-riscv64 jq-linux-s390x jq-linux64
jq-macos-amd64 jq-macos-arm64 jq-osx-amd64 jq-win64.exe jq-windows-amd64.exe jq-windows-i386.exe sha256sum.txt
]])
local FZF = names_to_assets([[
fzf-0.56.3-darwin_amd64.tar.gz fzf-0.56.3-darwin_arm64.tar.gz fzf-0.56.3-freebsd_amd64.tar.gz
fzf-0.56.3-linux_amd64.tar.gz fzf-0.56.3-linux_arm64.tar.gz fzf-0.56.3-linux_armv5.tar.gz
fzf-0.56.3-linux_armv6.tar.gz fzf-0.56.3-linux_armv7.tar.gz fzf-0.56.3-linux_loong64.tar.gz
fzf-0.56.3-linux_ppc64le.tar.gz fzf-0.56.3-linux_s390x.tar.gz fzf-0.56.3-openbsd_amd64.tar.gz
fzf-0.56.3-windows_amd64.zip fzf-0.56.3-windows_arm64.zip fzf-0.56.3-windows_armv5.zip
fzf-0.56.3-windows_armv6.zip fzf-0.56.3-windows_armv7.zip fzf_0.56.3_checksums.txt
]])

-- { assets, os, arch, expected asset (or false for "no match") }
local PLATFORM_CASES = {
    { RIPGREP, "linux", "amd64", "ripgrep-14.1.1-x86_64-unknown-linux-musl.tar.gz" },
    { RIPGREP, "linux", "arm64", "ripgrep-14.1.1-aarch64-unknown-linux-gnu.tar.gz" },
    { RIPGREP, "linux", "386", "ripgrep-14.1.1-i686-unknown-linux-gnu.tar.gz" },
    { RIPGREP, "darwin", "arm64", "ripgrep-14.1.1-aarch64-apple-darwin.tar.gz" },
    { RIPGREP, "darwin", "amd64", "ripgrep-14.1.1-x86_64-apple-darwin.tar.gz" },
    { RIPGREP, "windows", "amd64", "ripgrep-14.1.1-x86_64-pc-windows-msvc.zip" },
    { RIPGREP, "windows", "arm64", "ripgrep-14.1.1-x86_64-pc-windows-msvc.zip" },
    { GH, "linux", "amd64", "gh_2.63.0_linux_amd64.tar.gz" },
    { GH, "linux", "arm64", "gh_2.63.0_linux_arm64.tar.gz" },
    { GH, "linux", "386", "gh_2.63.0_linux_386.tar.gz" },
    { GH, "darwin", "arm64", "gh_2.63.0_macOS_arm64.zip" },
    { GH, "darwin", "amd64", "gh_2.63.0_macOS_amd64.zip" },
    { GH, "windows", "amd64", "gh_2.63.0_windows_amd64.zip" },
    { GH, "windows", "arm64", "gh_2.63.0_windows_arm64.zip" },
    { JQ, "linux", "amd64", "jq-linux-amd64" },
    { JQ, "linux", "arm64", "jq-linux-arm64" },
    { JQ, "linux", "386", "jq-linux-i386" },
    { JQ, "darwin", "arm64", "jq-macos-arm64" },
    { JQ, "darwin", "amd64", "jq-macos-amd64" },
    { JQ, "windows", "amd64", "jq-win64.exe" },
    { FZF, "linux", "amd64", "fzf-0.56.3-linux_amd64.tar.gz" },
    { FZF, "linux", "arm64", "fzf-0.56.3-linux_arm64.tar.gz" },
    { FZF, "linux", "386", false },
    { FZF, "darwin", "arm64", "fzf-0.56.3-darwin_arm64.tar.gz" },
    { FZF, "darwin", "amd64", "fzf-0.56.3-darwin_amd64.tar.gz" },
    { FZF, "windows", "amd64", "fzf-0.56.3-windows_amd64.zip" },
    { FZF, "windows", "arm64", "fzf-0.56.3-windows_arm64.zip" },
}
for i, case in ipairs(PLATFORM_CASES) do
    local label = "platform case " .. i .. " (" .. case[2] .. "/" .. case[3] .. ")"
    if case[4] then
        assert_eq(pick_on(case[2], case[3], case[1]), case[4], label)
    else
        assert_err(function()
            pick_on(case[2], case[3], case[1])
        end, "No matching release asset", label)
    end
end

-- #4: "win" must not match inside "darwin".
assert_eq(ghe.name_tokens("tool-darwin-arm64.tar.gz").win, nil, "no win token in darwin")
assert_eq(pick_on("darwin", "arm64", names_to_assets("tool-darwin-arm64.tar.gz")), "tool-darwin-arm64.tar.gz", "darwin")
assert_eq(
    pick_on("darwin", "amd64", names_to_assets("tool_Darwin_x86_64.tar.gz")),
    "tool_Darwin_x86_64.tar.gz",
    "Darwin x86_64"
)
assert_eq(
    pick_on("windows", "amd64", names_to_assets("tool-darwin-amd64.tar.gz tool-win64.zip")),
    "tool-win64.zip",
    "win64 on windows"
)
for _, os_type in ipairs({ "linux", "darwin" }) do
    assert_err(function()
        pick_on(os_type, "amd64", names_to_assets("tool-x86_64-pc-windows-msvc.zip tool-win64.zip"))
    end, "No matching release asset", "windows assets rejected on " .. os_type)
end

-- #5: wrong architecture is rejected rather than installed silently.
assert_err(function()
    pick_on("linux", "amd64", names_to_assets("tool-linux-arm64.tar.gz"))
end, "tool-linux-arm64.tar.gz", "foreign arch rejected, assets listed")
assert_err(function()
    pick_on("linux", "386", names_to_assets("tool-linux-x86_64.tar.gz"))
end, "No matching release asset", "x86_64 is not 386")
assert_eq(
    pick_on("linux", "amd64", names_to_assets("tool-linux-arm64.tar.gz"), { asset_pattern = "arm64" }),
    "tool-linux-arm64.tar.gz",
    "explicit pattern still allows a foreign arch"
)
-- Emulation and universal binaries.
assert_eq(
    pick_on("darwin", "arm64", names_to_assets("tool-darwin-amd64.tar.gz")),
    "tool-darwin-amd64.tar.gz",
    "Rosetta fallback"
)
assert_eq(
    pick_on("darwin", "arm64", names_to_assets("tool-darwin-amd64.tar.gz tool-darwin-universal.tar.gz")),
    "tool-darwin-universal.tar.gz",
    "universal beats emulation"
)
assert_eq(pick_on("darwin", "amd64", names_to_assets("tool_darwin_all.tar.gz")), "tool_darwin_all.tar.gz", "darwin_all")
-- OS packages are never auto-selected, and a pattern selecting only packages explains why.
for _, pkg in ipairs({
    "tool-linux-amd64.deb",
    "tool-linux-amd64.rpm",
    "tool-windows-amd64.msi",
    "tool-darwin-arm64.dmg",
}) do
    local os_type = pkg:match("%-(%a+)%-")
    local arch = pkg:match("%-(%w+)%.%a+$")
    assert_err(function()
        pick_on(os_type, arch, names_to_assets(pkg))
    end, "OS packages", "package not selected: " .. pkg)
end
assert_err(function()
    pick_on("linux", "amd64", names_to_assets("tool-linux-amd64.deb"), { asset_pattern = ".deb" })
end, "OS packages", "pattern selecting a package errors")
assert_eq(
    pick_on("linux", "amd64", names_to_assets("tool_1.0_amd64.deb tool-linux-amd64.tar.gz")),
    "tool-linux-amd64.tar.gz",
    "archive over deb"
)
-- Sidecars are never selected.
for _, sidecar in ipairs({
    "tool-linux-amd64.tar.gz.sha512",
    "tool-linux-amd64.tar.gz.intoto.jsonl",
    "tool-linux-amd64.tar.gz.pem",
    "tool-linux-amd64.sbom.json",
    "checksums.txt",
    "SHA256SUMS",
}) do
    assert_err(function()
        pick_on("linux", "amd64", { { name = sidecar } })
    end, "No matching release asset", "sidecar skipped: " .. sidecar)
end
-- "test" penalises the token, not substrings such as "latest".
assert_eq(
    pick_on("linux", "amd64", names_to_assets("tool-tests-linux-amd64.tar.gz tool-latest-linux-amd64.tar.gz")),
    "tool-latest-linux-amd64.tar.gz",
    "latest is not penalised"
)

assert_eq(ghe.is_archive("a.tar.gz"), true, "tar.gz")
assert_eq(ghe.is_archive("a.tgz"), true, "tgz")
assert_eq(ghe.is_archive("a.zip"), true, "zip")
assert_eq(ghe.is_archive("a"), false, "plain binary")

-- Asset formats and installation (#6).
assert_eq(ghe.is_archive("A.TAR.GZ"), true, "upper-case tar.gz")
assert_eq(ghe.is_archive("a.tar"), true, "tar")
assert_eq(ghe.is_archive("a.tar.zst"), true, "tar.zst")
assert_eq(ghe.is_archive("a.gz"), false, "single gz is not an archive")
assert_eq(ghe.asset_format("a.tgz").ext, ".tar.gz", "tgz canonical")
assert_eq(ghe.asset_format("a.TXZ").ext, ".tar.xz", "txz canonical")
assert_eq(ghe.asset_format("a.tbz2").ext, ".tar.bz2", "tbz2 canonical")
assert_eq(ghe.asset_format("a.tar.gz").kind, "archiver", "tar.gz via archiver")
assert_eq(ghe.asset_format("a.tar").kind, "tar", "tar via system tar")
assert_eq(ghe.asset_format("tool-linux-x64.gz").tool, "gzip", "single gz")
assert_eq(ghe.asset_format("tool.xz").tool, "xz", "single xz")
assert_eq(ghe.asset_format("tool.bz2").tool, "bzip2", "single bz2")
assert_eq(ghe.asset_format("tool.zst").tool, "zstd", "single zst")
assert_eq(ghe.asset_format("tool.7z").kind, "unsupported", "7z")
assert_eq(ghe.asset_format("tool-linux-amd64"), nil, "raw binary")
assert_eq(ghe.asset_format(".gz"), nil, "bare suffix is not a format")

-- install_asset with stubbed mise modules; records every call.
local function with_install_stubs(os_type, tar_listing, fn)
    local calls = {}
    local saved = {
        runtime = RUNTIME,
        file = package.loaded.file,
        archiver = package.loaded.archiver,
        cmd = package.loaded.cmd,
    }
    RUNTIME = { osType = os_type, archType = "amd64" }
    package.loaded.file = {
        join_path = function(...)
            return table.concat({ ... }, "/")
        end,
        move = function(from, to)
            table.insert(calls, "move " .. from .. " -> " .. to)
        end,
    }
    package.loaded.archiver = {
        decompress = function(archive, dest, opts)
            local strip = tostring(opts.strip_components)
            table.insert(calls, "decompress " .. archive .. " -> " .. dest .. " strip=" .. strip)
        end,
    }
    package.loaded.cmd = {
        exec = function(command)
            if command:find("ghe", 1, true) or command:find("/dl/", 1, true) then
                error("paths must be passed via env, not interpolated: " .. command)
            end
            table.insert(calls, "exec " .. command)
            if command:find("-tf", 1, true) then
                return tar_listing or ""
            end
            return ""
        end,
    }
    local ok, err = pcall(fn)
    RUNTIME = saved.runtime
    package.loaded.file = saved.file
    package.loaded.archiver = saved.archiver
    package.loaded.cmd = saved.cmd
    if not ok then
        error(err, 0)
    end
    return calls
end

local calls = with_install_stubs("linux", nil, function()
    ghe.install_asset("/dl/tool-linux-amd64.tgz", "/inst", {}, "tool")
end)
assert_eq(calls[1], "move /dl/tool-linux-amd64.tgz -> /dl/mise-ghe-asset.tar.gz", "tgz renamed for archiver")
assert_eq(calls[2], "decompress /dl/mise-ghe-asset.tar.gz -> /inst strip=1", "tgz extracted")

calls = with_install_stubs("linux", nil, function()
    ghe.install_asset("/dl/TOOL.TAR.GZ", "/inst", {}, "tool")
end)
assert_eq(calls[2], "decompress /dl/mise-ghe-asset.tar.gz -> /inst strip=1", "upper-case suffix normalized")

calls = with_install_stubs("linux", nil, function()
    ghe.install_asset("/dl/tool.tar.gz", "/inst", {}, "tool")
end)
assert_eq(calls[1], "move /dl/tool.tar.gz -> /dl/mise-ghe-asset.tar.gz", "tar.gz uses a fixed local name")

calls = with_install_stubs("linux", "tool-1.0/\ntool-1.0/bin/tool\n", function()
    ghe.install_asset("/dl/tool.tar", "/inst", {}, "tool")
end)
assert_eq(calls[1], 'exec tar -tf "$MISE_GHE_ARCHIVE"', "tar listed")
assert_eq(calls[2], 'exec tar -xf "$MISE_GHE_ARCHIVE" -C "$MISE_GHE_DEST" --strip-components=1', "single dir stripped")

calls = with_install_stubs("linux", "./tool\n./README.md\n", function()
    ghe.install_asset("/dl/tool.tar.zst", "/inst", {}, "tool")
end)
assert_eq(calls[2], 'exec tar -xf "$MISE_GHE_ARCHIVE" -C "$MISE_GHE_DEST"', "root files kept")

calls = with_install_stubs("linux", nil, function()
    ghe.install_asset("/dl/tool-linux-x64.gz", "/inst", { bin = "tree-sitter" }, "tool")
end)
assert_eq(calls[1], 'exec gzip -dc "$MISE_GHE_SOURCE" > "$MISE_GHE_DEST"', "gz decompressed, not moved")
assert_eq(calls[2], 'exec chmod +x "$MISE_GHE_BIN"', "decompressed binary made executable")
assert_eq(#calls, 2, "no move of the compressed file")

calls = with_install_stubs("linux", nil, function()
    ghe.install_asset("/dl/tool-linux-amd64", "/inst", {}, "tool")
end)
assert_eq(calls[1], "move /dl/tool-linux-amd64 -> /inst/tool", "raw binary moved")

assert_err(function()
    with_install_stubs("windows", nil, function()
        ghe.install_asset("/dl/tool-windows-x64.gz", "/inst", {}, "tool")
    end)
end, "not supported on Windows", "single gz on windows")
assert_err(function()
    with_install_stubs("linux", nil, function()
        ghe.install_asset("/dl/tool.7z", "/inst", {}, "tool")
    end)
end, "Unsupported asset format .7z", "7z rejected")

local releases = {
    {
        tag_name = "v1.2.3",
        draft = false,
        assets = {
            { name = "tool-linux-amd64.tar.gz", url = "https://ghe.example/api/v3/repos/org/tool/releases/assets/1" },
            { name = "tool-windows-amd64.zip", url = "https://ghe.example/api/v3/repos/org/tool/releases/assets/2" },
        },
    },
    {
        tag_name = "v1.0.0",
        draft = false,
        assets = {
            { name = "tool-linux-amd64.tar.gz", url = "https://ghe.example/api/v3/repos/org/tool/releases/assets/3" },
        },
    },
    {
        tag_name = "v9.9.9",
        draft = true,
        assets = {
            { name = "tool-linux-amd64.tar.gz", url = "https://ghe.example/api/v3/repos/org/tool/releases/assets/4" },
        },
    },
}

local versions = ghe.versions_from_releases(releases)
assert_eq(versions[1], "1.0.0", "oldest first")
assert_eq(versions[2], "1.2.3", "newest last")
assert_eq(#versions, 2, "skip draft")

local rel = ghe.find_release(releases, "1.2.3")
assert_eq(rel.tag_name, "v1.2.3", "find stripped")
rel = ghe.find_release(releases, "v1.0.0")
assert_eq(rel.tag_name, "v1.0.0", "find v-prefix")
assert_err(function()
    ghe.find_release(releases, "9.9.9")
end, "Unknown version", "draft not found")
assert_err(function()
    ghe.find_release(releases, "0.0.1")
end, "Unknown version", "missing version")

local asset = ghe.pick_asset(releases[1].assets, {})
assert_eq(asset.name, "tool-linux-amd64.tar.gz", "pick linux")
asset = ghe.pick_asset(releases[1].assets, { asset_pattern = "windows" })
assert_eq(asset.name, "tool-windows-amd64.zip", "pattern")
assert_err(function()
    ghe.pick_asset(releases[1].assets, { matching = "nope" })
end, "Available assets", "no match lists names")
assert_err(function()
    ghe.pick_asset({ { name = "tool-linux-amd64.tar.gz.sha256" } }, {})
end, "Available assets", "skip checksum")
assert_err(function()
    ghe.pick_asset({ { name = "tool-windows-amd64.zip" } }, {})
end, "Available assets", "skip foreign os")

assert_eq(ghe.bin_name({ bin = "custom" }, "repo"), "custom", "bin")
assert_eq(ghe.bin_name({ rename_exe = "renamed" }, "repo"), "renamed", "rename")
assert_eq(ghe.bin_name({}, "repo"), "repo", "default repo")
assert_eq(ghe.bin_name({ bin = "../evil" }, "repo"), "evil", "bin basename")
assert_err(function()
    ghe.bin_name({ bin = ".." }, "repo")
end, "Invalid binary name", "reject .. bin")

-- Windows needs an executable extension (#9).
local function bin_name_on(os_type, ...)
    local saved = RUNTIME
    RUNTIME = { osType = os_type, archType = "amd64" }
    local ok, res = pcall(ghe.bin_name, ...)
    RUNTIME = saved
    if not ok then
        error(res, 0)
    end
    return res
end
assert_eq(bin_name_on("windows", {}, "jq", "jq-windows-amd64.exe"), "jq.exe", "windows adds .exe")
assert_eq(bin_name_on("windows", {}, "jq"), "jq.exe", "windows defaults to .exe")
assert_eq(bin_name_on("windows", { bin = "jq.exe" }, "repo", "jq.exe"), "jq.exe", "no double .exe")
assert_eq(bin_name_on("windows", { bin = "JQ.EXE" }, "repo"), "JQ.EXE", "existing extension in any case")
assert_eq(bin_name_on("windows", { bin = "tool" }, "repo", "tool-windows.cmd"), "tool.cmd", "keeps .cmd runnable")
assert_eq(bin_name_on("linux", {}, "jq", "jq-linux-amd64"), "jq", "no extension on linux")
assert_eq(bin_name_on("darwin", {}, "jq", "jq.exe"), "jq", "no extension on macOS")
calls = with_install_stubs("windows", nil, function()
    ghe.install_asset("/dl/jq-windows-amd64.exe", "/inst", {}, "jq")
end)
assert_eq(calls[1], "move /dl/jq-windows-amd64.exe -> /inst/jq.exe", "windows raw .exe keeps its extension")
assert_eq(#calls, 1, "no chmod on windows")

if not os.getenv("MISE_GHE_API_URL") and not os.getenv("GHE_API_URL") then
    assert_err(function()
        ghe.api_url({})
    end, "MISE_GHE_API_URL", "missing api_url")
end

print("ghe_check: ok")
