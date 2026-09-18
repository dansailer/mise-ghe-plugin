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

## Global configuration

To make the plugin and GHE API URL available in every directory, add them to
`~/.config/mise/config.toml` (or the path configured by `MISE_GLOBAL_CONFIG_FILE`):

```toml
[plugins]
ghe = "https://github.com/dansailer/mise-ghe-plugin.git"

[tools]
github-cli = "latest"
"ghe:myorg/mytool" = "1.2.3"

[env]
MISE_GHE_API_URL = "https://github.mycompany.com/api/v3"
GH_CONFIG_DIR = "{{config_root}}/.config/gh"
```

For a single internal GHE host, configure the API URL and GitHub CLI once
globally. Individual GHE tools only need their `org/repo` name and version.

Then install the plugin and globally configured tools:

```sh
mise plugins install ghe
mise install
```

The same settings can be written with commands:

```sh
mise config set --global plugins.ghe https://github.com/dansailer/mise-ghe-plugin.git
mise config set --global env.MISE_GHE_API_URL https://github.mycompany.com/api/v3
mise config set --global env.GH_CONFIG_DIR '{{config_root}}/.config/gh'
mise use --global github-cli@latest
mise use --global 'ghe:myorg/mytool@1.2.3'
```

For a local checkout during development, link the plugin instead of using the
git URL:

```sh
mise plugins link --force ghe /path/to/mise-ghe-plugin
```

`MISE_GHE_API_URL` must be an HTTPS API root, typically ending in `/api/v3`.
For this single-host setup, omit per-tool `api_url` options. They remain
available only when an exceptional tool must use another GHE host. Avoid
storing tokens in the global config; use `gh auth login --hostname ...` or a
token environment variable instead.

## Environment

| Variable | Required | Purpose |
|----------|----------|---------|
| `MISE_GHE_API_URL` | yes, unless `api_url` is set per tool | GHE API root, e.g. `https://github.mycompany.com/api/v3` |
| `GHE_API_URL` | no | Fallback if `MISE_GHE_API_URL` is unset |
| `GH_CONFIG_DIR` | no | Optional directory containing the GitHub CLI `hosts.yml`; useful when set globally |
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

The `gh` fallback assumes that the GitHub CLI is installed separately; this
plugin does not install `gh`. It works with `gh` on the system `PATH` or with
mise's `github-cli` tool. Backend hooks run with a sanitized environment, so
the plugin adds mise's `shims` directory when the plugin uses the standard
`<MISE_DATA_DIR>/plugins/ghe` layout and searches ancestor directories for an
existing `gh/hosts.yml` at these standard locations:

- Unix: `.config/gh/hosts.yml`
- Windows: `AppData/Roaming/GitHub CLI/hosts.yml`
- macOS: `Library/Application Support/gh/hosts.yml`

If `gh` is installed in a custom location or its configuration is elsewhere,
make `gh` available on `PATH` and set `GH_CONFIG_DIR` to the directory
containing `hosts.yml`, for example in the global mise config:

```toml
[env]
GH_CONFIG_DIR = "/custom/path/to/gh"
```

If the CLI or its config cannot be found, `gh auth token` is treated as an
unavailable credential and the plugin falls through to the token environment
variables. For a private repository, that eventually appears as an API `401`,
not as a `gh` process error. Set `MISE_GITHUB_ENTERPRISE_TOKEN` or
`MISE_GHE_TOKEN` explicitly when using a non-standard setup.

For **private** release assets the token needs **Contents: read**. Downloads use the API asset URL (`asset.url`) with `Accept: application/octet-stream` and `Authorization` only when that URL is HTTPS on the same host as `api_url`. `browser_download_url` is a same-host fallback without `Authorization`.

## Tool options

| Option | Purpose |
|--------|---------|
| `api_url` | Optional per-tool GHE API root override; normally use global `MISE_GHE_API_URL` |
| `asset_pattern` / `matching` | Keep assets whose name contains this substring, then pick by OS/arch score (also allows a foreign-OS asset) |
| `bin` | Name for a single (non-archive) binary; default is the repo name |
| `rename_exe` | Deprecated synonym for `bin`; use `bin` instead |
| `token` | Per-tool token (prefer env vars) |

## Example `mise.toml`

```toml
[plugins]
ghe = "https://github.mycompany.com/platform/mise-ghe"

[tools]
"ghe:myorg/mytool" = "1.2.3"
"ghe:myorg/other" = { version = "latest", asset_pattern = "linux-amd64" }
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
