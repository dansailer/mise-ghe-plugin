# mise-ghe-plugin

[![CI](https://github.com/dansailer/mise-ghe-plugin/actions/workflows/ci.yml/badge.svg)](https://github.com/dansailer/mise-ghe-plugin/actions/workflows/ci.yml)

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

The plugin resolves credentials in this order. Each token is only sent to the host it belongs to:

| Priority | Source | Sent to |
|----------|--------|---------|
| 1 | Tool option `token` (avoid — do not store tokens in `mise.toml`) | that tool's `api_url` |
| 2 | `MISE_GITHUB_ENTERPRISE_TOKEN`, then `MISE_GHE_TOKEN` | the host of `MISE_GHE_API_URL` / `GHE_API_URL`, and hosts listed in `MISE_GHE_TOKEN_HOSTS` |
| 3 | `gh auth token` for the API hostname (recommended) | the host gh issued it for |
| 4 | `MISE_GITHUB_TOKEN`, then `GITHUB_TOKEN`, then `GITHUB_API_TOKEN` | `github.com`, the GitHub Actions server (`GITHUB_SERVER_URL`, so a GHES runner's `GITHUB_TOKEN` works), or the GHE hosts from row 2 when `MISE_GHE_ALLOW_GITHUB_TOKEN=1` |

When a token variable is set but withheld from a host, mise prints a warning naming the variable (never its value) and how to allow it.

**Per-tool `api_url` on another host:** a tool whose `api_url` points at a different host does not receive `MISE_GHE_TOKEN`/`MISE_GITHUB_ENTERPRISE_TOKEN`. Log in with `gh auth login --hostname <host>`, or list the host explicitly:

```toml
[env]
MISE_GHE_API_URL     = "https://github.mycompany.com/api/v3"
MISE_GHE_TOKEN_HOSTS = "github.other.com"   # comma-separated hostnames or URLs
```

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
| `MISE_GHE_TOKEN_HOSTS` | Token for a per-tool `api_url` host | Extra hosts (comma-separated) that may receive `MISE_GITHUB_ENTERPRISE_TOKEN` / `MISE_GHE_TOKEN` |
| `MISE_GITHUB_TOKEN` / `GITHUB_TOKEN` / `GITHUB_API_TOKEN` | Last resort | Generic token fallback; sent only to `github.com` or the Actions server unless `MISE_GHE_ALLOW_GITHUB_TOKEN=1` |
| `MISE_GHE_ALLOW_GITHUB_TOKEN` | Generic token for GHE | Set to `1` to also send the generic tokens to the GHE hosts |

`MISE_GHE_API_URL` must use HTTPS. Trailing slashes are stripped. Userinfo (`user:pass@`) is rejected — use a token env var instead.

---

## Tool options

Supported release assets: archives (`.tar.gz`/`.tgz`, `.tar.xz`/`.txz`, `.tar.bz2`/`.tbz2`, `.zip`; `.tar` and `.tar.zst` via the system `tar`), single compressed binaries (`.gz`, `.xz`, `.bz2`, `.zst`, decompressed with the matching tool; not on Windows), and raw binaries. Archives are extracted with one top-level directory stripped; single binaries are installed as `bin` (default: the repo name).

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

### How the release asset is chosen

Asset names are split into tokens (`tool_2.0_linux_amd64.tar.gz` → `tool`, `2.0`, `linux`, `amd64`), and the plugin picks the best-scoring asset for the current platform:

- Checksum and signature files (`.sha256`, `.sha512`, `.sig`, `.pem`, `.intoto.jsonl`, `checksums.txt`, `SHA256SUMS`, …) and OS packages (`.deb`, `.rpm`, `.msi`, `.pkg`, `.dmg`, …) are never installed.
- Assets labelled for another OS or another architecture are rejected, so a missing build fails with the list of available assets instead of installing the wrong binary.
- A native architecture beats a universal macOS binary (`universal`, `darwin_all`), which beats an emulated one: `amd64` on Apple Silicon (Rosetta 2) and `amd64`/`x86` on Windows on Arm.
- Archives are preferred over bare binaries, `msvc` over `gnu` on Windows, and glibc over `musl` builds. Names with `debug`/`test` tokens score lower.

If the choice is wrong, set `asset_pattern` (alias `matching`): only assets whose name contains that substring are considered, and they may be for another OS or architecture.

---

## Uninstall

```sh
# Remove each ghe: tool from the global config, then remove the plugin and its installs
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
