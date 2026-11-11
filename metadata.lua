PLUGIN = {
    name = "ghe",
    version = "0.1.0",
    description = "Install GitHub Enterprise release assets as ghe:org/repo",
    homepage = "https://github.com/dansailer/mise-ghe-plugin",
    author = "Daniel Sailer (dansailer)",
    license = "MIT",
    notes = {
        "Set MISE_GHE_API_URL or tool option api_url (.../api/v3).",
        "Authenticate with gh auth login or a token env var; see the README for which token is sent where.",
    },
}
