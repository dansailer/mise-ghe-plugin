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
| `MISE_GITHUB_TOKEN` | for private repos | After `gh` |
| `GITHUB_TOKEN` | for private repos | After `gh` |
| `GITHUB_API_TOKEN` | for private repos | Last fallback after `gh` |

There is no default to `api.github.com`. The API URL must be `https://` (trailing slashes are stripped; userinfo is rejected).

Token resolution order:

1. Tool option `token` (discouraged — do not put tokens in `mise.toml`)
2. `MISE_GITHUB_ENTERPRISE_TOKEN`, then `MISE_GHE_TOKEN`
3. `gh auth token` for the API hostname
4. `MISE_GITHUB_TOKEN`, then `GITHUB_TOKEN`, then `GITHUB_API_TOKEN`

Public GHE repos work without a token. `gh` is tried **before** generic `GITHUB_TOKEN` so a github.com token in the environment does not hide a GHE `gh` login.

`gh` fallback requires the GitHub CLI on `PATH` and a login for that host:

```sh
gh auth login --hostname github.mycompany.com
# Contents: read is enough for private release assets
```

The plugin runs `gh auth token` with `GH_HOST` set from `api_url` (for example `https://github.mycompany.com/api/v3` → `github.mycompany.com`). If the API host starts with `api.`, it also tries the name without that prefix (`api.company.ghe.com` → `company.ghe.com`). Prompts are disabled (`GH_PROMPT_DISABLED`). The token is never printed.

For **private** release assets the token needs **Contents: read**. Downloads use the API asset URL (`asset.url`) with `Accept: application/octet-stream` and `Authorization` only when that URL is HTTPS on the same host as `api_url`. `browser_download_url` is a same-host fallback without `Authorization`.

## Tool options

| Option | Purpose |
|--------|---------|
| `api_url` | Per-tool GHE API root (overrides env) |
| `asset_pattern` / `matching` | Keep assets whose name contains this substring, then pick by OS/arch score (also allows a foreign-OS asset) |
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
