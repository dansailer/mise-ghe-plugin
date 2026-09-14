local ghe = require("ghe")

function PLUGIN:BackendListVersions(ctx)
    local options = ctx.options or {}
    local owner, repo = ghe.parse_tool(ctx.tool)
    local api_url = ghe.api_url(options)
    local token = ghe.token(options, api_url)
    local releases = ghe.list_releases(api_url, owner, repo, token)
    local versions = ghe.versions_from_releases(releases)
    if #versions == 0 then
        error(
            "No releases found for "
                .. owner
                .. "/"
                .. repo
                .. " (drafts are skipped). Check org/repo and api_url."
        )
    end
    return { versions = versions }
end
