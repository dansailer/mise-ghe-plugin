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
assert_eq(ghe.host_from_api_url("https://user:pass@github.mycompany.com:443/api/v3"), "github.mycompany.com", "strip userinfo/port")
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
assert_eq(seen_gh_env.PATH:sub(1, #"/home/test/.local/share/mise/shims"), "/home/test/.local/share/mise/shims", "mise shims path")
package.loaded.cmd = prev_cmd
package.loaded.file = prev_file
os.getenv = prev_getenv
RUNTIME = prev_runtime

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
assert_eq(ghe.pick_asset({ linux_asset, sum_asset },  {}).name, "tool-linux-amd64.tar.gz", "prefer archive over checksum")

assert_eq(ghe.is_archive("a.tar.gz"), true, "tar.gz")
assert_eq(ghe.is_archive("a.tgz"), true, "tgz")
assert_eq(ghe.is_archive("a.zip"), true, "zip")
assert_eq(ghe.is_archive("a"), false, "plain binary")

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

if not os.getenv("MISE_GHE_API_URL") and not os.getenv("GHE_API_URL") then
    assert_err(function()
        ghe.api_url({})
    end, "MISE_GHE_API_URL", "missing api_url")
end

print("ghe_check: ok")
