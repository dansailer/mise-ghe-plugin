# ghe

mise backend plugin for **GitHub Enterprise** release binaries. Tools install as `ghe:org/repo`.

Use this for internal GHE assets. Public github.com tools should stay on mise's built-in `github:` backend.

## Quickstart

```sh
mise plugin link --force ghe .
export MISE_GHE_API_URL=https://github.mycompany.com/api/v3
export MISE_GITHUB_ENTERPRISE_TOKEN=...   # or MISE_GHE_TOKEN / GITHUB_TOKEN

mise ls-remote ghe:myorg/mytool
mise install ghe:myorg/mytool@1.2.3
mise use ghe:myorg/mytool@latest
mise exec -- mytool --version
```

Or declare the plugin from git:

```toml
[plugins]
ghe = "https://github.mycompany.com/platform/mise-ghe"
```

The backend prefix is the **install name** (`ghe` in `mise plugin link ghe ...`), not the repo directory name.

## Environment

| Variable | Required | Purpose |
|----------|----------|---------|
| `MISE_GHE_API_URL` | yes, unless `api_url` is set per tool | GHE API root, e.g. `https://github.mycompany.com/api/v3` |
| `GHE_API_URL` | no | Fallback if `MISE_GHE_API_URL` is unset |
| `MISE_GITHUB_ENTERPRISE_TOKEN` | for private repos | Preferred token |
| `MISE_GHE_TOKEN` | for private repos | Next token fallback |
| `MISE_GITHUB_TOKEN` | for private repos | Next token fallback |
| `GITHUB_TOKEN` | for private repos | Next token fallback |
| `GITHUB_API_TOKEN` | for private repos | Last token fallback |

There is no default to `api.github.com`. Trailing slashes on the API URL are stripped.

Token resolution order: tool option `token` (discouraged), then the env vars above, then **`gh auth token`** for the API hostname. Public GHE repos work without a token.

`gh` fallback requires the GitHub CLI on `PATH` and a login for that host:

```sh
gh auth login --hostname github.mycompany.com
# Contents: read is enough for private release assets
```

The plugin runs `gh auth token` with `GH_HOST` set from `api_url` (for example `https://github.mycompany.com/api/v3` → `github.mycompany.com`). If the API host starts with `api.`, it also tries the name without that prefix (`api.company.ghe.com` → `company.ghe.com`). Env vars still win over `gh`. The token is never printed.

For **private** release assets the token needs **Contents: read**. Assets are downloaded from the API asset URL (`Accept: application/octet-stream`), not from `browser_download_url` alone.

## Tool options

| Option | Purpose |
|--------|---------|
| `api_url` | Per-tool GHE API root (overrides env) |
| `asset_pattern` / `matching` | Keep assets whose name contains this string or matches it as a Lua pattern, then still pick by OS/arch score |
| `bin` / `rename_exe` | Name for a single (non-archive) binary; default is the repo name |
| `token` | Per-tool token (prefer env vars) |

## Example `mise.toml`

```toml
[plugins]
ghe = "https://github.mycompany.com/platform/mise-ghe"

[tools]
"ghe:myorg/mytool" = "1.2.3"
"ghe:myorg/other" = { version = "latest", api_url = "https://github.mycompany.com/api/v3", asset_pattern = "linux-amd64" }
```

Inline options:

```text
ghe:org/repo
ghe:org/repo@1.2.3
ghe:org/repo[api_url=https://github.example.com/api/v3]@latest
```

`ls-remote` lists non-draft tags oldest → newest and strips a single leading `v` (`v1.2.3` → `1.2.3`).

## License

MIT. Manual checks: [test/ghe_spec.md](test/ghe_spec.md).
