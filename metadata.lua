PLUGIN = {
    name = "ghe",
    version = "0.1.0",
    description = "Install GitHub Enterprise release assets as ghe:org/repo",
    author = "internal",
    license = "MIT",
    -- When the user configures github-cli, mise installs it first and puts its
    -- real gh (not the shim) on PATH for this plugin's hooks.
    depends = { "github-cli" },
    notes = {
        "Set MISE_GHE_API_URL or tool option api_url (.../api/v3).",
        "Auth: tool option token, MISE_GITHUB_ENTERPRISE_TOKEN/MISE_GHE_TOKEN (only for the MISE_GHE_API_URL host"
            .. " and MISE_GHE_TOKEN_HOSTS), gh auth token, then GITHUB_TOKEN (only for github.com unless"
            .. " MISE_GHE_ALLOW_GITHUB_TOKEN=1).",
    },
}
