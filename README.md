# mise-ghe-plugin

A [mise](https://mise.jdx.dev) backend plugin that installs tools from **GitHub Enterprise** release assets.

Use `ghe:org/repo` to install internal tools from your GHE instance. For public GitHub tools, use mise's built-in `github:` backend instead.

---

## Install

```sh
# 1. Install the plugin
mise plugins install ghe "https://github.com/dansailer/mise-ghe-plugin"

# 2. Set your GHE API URL
mise config set --global env.MISE_GHE_API_URL "https://github.mycompany.com/api/v3"

# 3. Authenticate
gh auth login --hostname github.mycompany.com
```

---

## Setup

Add this to `~/.config/mise/config.toml` (your global mise config):

```toml
[plugins]
ghe = "https://github.com/dansailer/mise-ghe-plugin"

[tools]
github-cli = "latest"           # provides gh for authentication
"ghe:myorg/mytool" = "1.2.3"   # add your tools here

[env]
MISE_GHE_API_URL = "https://github.mycompany.com/api/v3"
GH_CONFIG_DIR    = "{{config_root}}/.config/gh"
```

For one internal GHE host, set `MISE_GHE_API_URL` once globally. Each tool only needs its `org/repo` and version — no per-tool API URL.

Then install:

```sh
mise install
```

---

## Authentication

The plugin resolves credentials in this order:

| Priority | Source |
|----------|--------|
| 1 | Tool option `token` (avoid — do not store tokens in `mise.toml`) |
| 2 | `MISE_GITHUB_ENTERPRISE_TOKEN`, then `MISE_GHE_TOKEN` |
| 3 | `gh auth token` for the API hostname (recommended) |
| 4 | `MISE_GITHUB_TOKEN`, then `GITHUB_TOKEN`, then `GITHUB_API_TOKEN` |

**Recommended:** use `gh auth login`. The plugin calls `gh auth token` automatically — no token env var needed.

```sh
gh auth login --hostname github.mycompany.com
# Requires: Contents: read (for private release assets)
```

> **If you get a 401 error:** Verify that the configured token or `gh` login is valid for the API host. If `gh` or its config cannot be found, check the [gh not found](#gh-not-found) section below.

### gh not found

The plugin runs in a sanitized environment — your shell's `PATH` and `HOME` are not automatically available. It recovers them from standard locations based on the plugin directory, checking:

| Platform | Config location |
|----------|----------------|
| Unix | `~/.config/gh/hosts.yml` |
| macOS | `~/Library/Application Support/gh/hosts.yml` |
| Windows | `%APPDATA%\GitHub CLI\hosts.yml` |

If your `gh` config is elsewhere, set `GH_CONFIG_DIR` in your global mise config:

```toml
[env]
GH_CONFIG_DIR = "/custom/path/to/gh-config"
```

---

## Environment variables

| Variable | When required | Purpose |
|----------|--------------|---------|
| `MISE_GHE_API_URL` | Always (unless `api_url` set per tool) | GHE API root, e.g. `https://github.mycompany.com/api/v3` |
| `GHE_API_URL` | — | Fallback if `MISE_GHE_API_URL` is unset |
| `GH_CONFIG_DIR` | Non-standard gh setup | Directory containing `hosts.yml` |
| `MISE_GITHUB_ENTERPRISE_TOKEN` | Private repos, no `gh` login | Preferred explicit token |
| `MISE_GHE_TOKEN` | Private repos, no `gh` login | Fallback token |
| `MISE_GITHUB_TOKEN` / `GITHUB_TOKEN` / `GITHUB_API_TOKEN` | Last resort | Generic token fallback |

`MISE_GHE_API_URL` must use HTTPS. Trailing slashes are stripped. Userinfo (`user:pass@`) is rejected — use a token env var instead.

---

## Tool options

| Option | Purpose |
|--------|---------|
| `api_url` | Override the GHE API root for one tool (use global `MISE_GHE_API_URL` instead when possible) |
| `asset_pattern` / `matching` | Filter assets by substring, then pick by OS/arch score |
| `bin` | Binary name for a non-archive asset (default: repo name) |
| `rename_exe` | Deprecated — use `bin` |
| `token` | Per-tool token (use env vars instead) |

### Examples

Most tools only need a version:

```toml
[tools]
"ghe:myorg/mytool" = "1.2.3"
"ghe:myorg/other"  = { version = "latest", asset_pattern = "linux-amd64" }
```

If one tool lives on a different GHE host, override `api_url` for that tool only:

```toml
[tools]
"ghe:myorg/mytool"   = "1.2.3"
"ghe:other/external" = { version = "latest", api_url = "https://github.other.com/api/v3" }
```

The same override works inline:

```text
ghe:org/repo[api_url=https://github.other.com/api/v3]@latest
```

All other tools continue to use the global `MISE_GHE_API_URL`.

`ls-remote` lists non-draft versions oldest → newest and strips a leading `v` (`v1.2.3` → `1.2.3`).

---

## Uninstall

```sh
# Remove all tools installed via this plugin, then remove the plugin itself
mise unuse --global 'ghe:myorg/mytool'       # repeat for each ghe: tool
mise plugins uninstall --purge ghe

# Remove the env vars from the global config
mise unset --global MISE_GHE_API_URL
mise unset --global GH_CONFIG_DIR

# Remove the github-cli tool if it was added for this plugin
mise unuse --global github-cli
```

The `[plugins]` entry (`ghe = "..."`) has no CLI removal command — delete that line from `~/.config/mise/config.toml` manually.

---

## License

MIT. Manual checks: [test/ghe_spec.md](test/ghe_spec.md).
