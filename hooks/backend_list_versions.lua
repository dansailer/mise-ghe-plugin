local ghe = require("ghe")

function PLUGIN:BackendListVersions(ctx)
    local options = ctx.options or {}
    local owner, repo = ghe.parse_tool(ctx.tool)
    local api_url = ghe.api_url(options)
    local token = ghe.token(options, api_url)
    local releases = ghe.list_releases(api_url, owner, repo, token)
    local include_prereleases = ghe.include_prereleases(options)
    local latest = ghe.latest_release_tag(api_url, owner, repo, token)
    local versions = ghe.versions_from_releases(releases, include_prereleases, latest)
    if #versions == 0 then
        error(
            "No releases found for "
                .. owner
                .. "/"
                .. repo
                .. " (drafts and, unless prerelease = true, prereleases are skipped). Check org/repo and api_url."
        )
    end
    return { versions = versions }
end
