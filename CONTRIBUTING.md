# Contributing

Thanks for helping. Bug reports, fixes and new asset formats are welcome.

## Before you start

- For a bug, open an issue with the [bug report form](https://github.com/dansailer/mise-ghe-plugin/issues/new/choose). Redact tokens from any output you paste.
- For a larger change, open an issue first so we can agree on the approach.
- For a security problem, follow [SECURITY.md](SECURITY.md) instead of opening an issue.

## Layout

| Path | Contents |
|------|----------|
| `metadata.lua` | Plugin name, version and dependencies |
| `hooks/` | The mise backend hooks: list versions, install, exec env |
| `lib/ghe.lua` | All logic: API URL, tokens, release and asset selection, download, install |
| `test/ghe_check.lua` | Offline unit tests; mise's Lua modules (`http`, `cmd`, `file`, ...) are stubbed |
| `test/smoke.sh` | End-to-end install with a real mise, used by CI |

The plugin runs in mise's embedded Lua 5.1. Only use the [mise Lua modules](https://mise.jdx.dev/plugin-lua-modules.html) and the Lua standard library.

## Checks

```sh
lua5.1 test/ghe_check.lua    # unit tests
luacheck .                   # lint (.luacheckrc)
```

For behaviour changes, add a test to `test/ghe_check.lua` that fails without your change.

## Testing with mise

Link your checkout and use isolated mise directories so your own setup is untouched:

```sh
export MISE_DATA_DIR=$PWD/.tmp/data MISE_CACHE_DIR=$PWD/.tmp/cache MISE_STATE_DIR=$PWD/.tmp/state \
       MISE_CONFIG_DIR=$PWD/.tmp/config MISE_GLOBAL_CONFIG_FILE=$PWD/.tmp/config.toml
mise plugins link --force ghe .
```

Public github.com repositories work for most checks (`MISE_GHE_API_URL=https://api.github.com`):

```sh
MISE_GHE_API_URL=https://api.github.com test/smoke.sh ripgrep@14.1.1=rg jq@jq-1.7.1=jq
MISE_DEBUG=1 mise install ghe:BurntSushi/ripgrep@14.1.1
```

### Against a real GitHub Enterprise Server

```sh
export MISE_GHE_API_URL=https://ghe.example.com/api/v3
gh auth login --hostname ghe.example.com       # or export MISE_GHE_TOKEN
mise ls-remote ghe:org/known-tool
mise install ghe:org/known-tool@<version>
mise exec ghe:org/known-tool@<version> -- <binary> --version
```

Expect:

- `ls-remote` prints versions oldest → newest, without a leading `v` for `vX.Y.Z` tags.
- `install` downloads the asset from the API asset URL with `Accept: application/octet-stream`, sending the token only to the `api_url` host.
- A private repository without a token fails with a 404 that says no token was sent.

Never print or log a token, and never interpolate paths or tokens into `cmd.exec` command strings: pass them through `env`.

## Commits and pull requests

- Use [Conventional Commits](https://www.conventionalcommits.org): `fix(install): ...`, `feat: ...`, `docs: ...`, `ci: ...`.
- Keep pull requests focused on one change and add a line to the `Unreleased` section of [CHANGELOG.md](CHANGELOG.md).
- CI (lint, unit tests, smoke installs on Linux, macOS and Windows) must pass.
