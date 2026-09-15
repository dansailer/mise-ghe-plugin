PLUGIN = {
    name = "ghe",
    version = "0.1.0",
    description = "Install GitHub Enterprise release assets as ghe:org/repo",
    author = "internal",
    license = "MIT",
    notes = {
        "Set MISE_GHE_API_URL or tool option api_url (.../api/v3).",
        "Auth: MISE_GITHUB_ENTERPRISE_TOKEN, then MISE_GHE_TOKEN, then gh auth token, then GITHUB_TOKEN.",
    },
}
