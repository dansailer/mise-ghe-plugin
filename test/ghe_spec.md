# ghe plugin checks

No live GitHub Enterprise host is required for CI. Use this list against a real GHE when you have one.

## Manual (needs GHE)

```sh
mise plugin link --force ghe .
export MISE_GHE_API_URL=https://github.mycompany.com/api/v3
export MISE_GITHUB_ENTERPRISE_TOKEN=...   # or: gh auth login --hostname github.mycompany.com
mise ls-remote ghe:org/known-tool
mise install ghe:org/known-tool@<version>
mise exec -- <binary> --version
```

Expect:

- `ls-remote` hits `{api_url}/repos/org/known-tool/releases` and prints versions oldest → newest, without a leading `v` when tags are `vX.Y.Z`.
- `install` downloads the platform asset from the **API** asset URL (`asset.url`) with `Accept: application/octet-stream` and `Authorization` only for an HTTPS URL on the same host as `api_url`.
- The binary is on PATH via `BackendExecEnv` (`install_path` and `install_path/bin` if that dir exists).

## Failure messages

| Case | Expect an explicit error mentioning |
|------|-------------------------------------|
| missing `api_url` | `MISE_GHE_API_URL` / `GHE_API_URL` / tool option `api_url`, plus an example `…/api/v3` |
| HTTP `api_url` | must be HTTPS |
| 401 / 403 | token env vars (`MISE_GITHUB_ENTERPRISE_TOKEN`, `MISE_GHE_TOKEN`, `GITHUB_TOKEN`) and/or `gh auth login --hostname` |
| 404 repo | org/repo and `api_url` |
| no matching asset | available asset names |
| unknown version | `Unknown version` and a sample of available versions |

Do not print the token. `file.mkdir` / `file.chmod` / interpolating paths or tokens into `cmd.exec` strings must not appear in the plugin.

## Offline inspection

Pure helpers in `lib/ghe.lua` (by inspection or a Lua 5.1 REPL with a fake `RUNTIME`):

```lua
-- normalize_tag
--   v1.2.3        -> 1.2.3
--   1.2.3-rc.1    -> 1.2.3-rc.1
--   release-1.2   -> release-1.2

-- parse_tool
--   org/repo          -> org, repo
--   org/repo/unused   -> org, repo
--   org               -> error (missing slash)

-- score_asset (linux + amd64), higher wins
--   tool-linux-amd64.tar.gz          high (OS + arch + archive)
--   tool-linux-amd64-musl.tar.gz     slightly lower (musl -5)
--   tool-windows-amd64.zip           lower (foreign OS)
--   tool-linux-amd64.tar.gz.sha256   much lower (checksum)
```

Fake release payload for `find_release` / `versions_from_releases`:

```json
[
  {"tag_name": "v1.2.3", "draft": false, "assets": [{"name": "tool-linux-amd64.tar.gz", "url": "https://ghe.example/api/v3/repos/org/tool/releases/assets/1"}]},
  {"tag_name": "v1.0.0", "draft": false, "assets": [{"name": "tool-linux-amd64.tar.gz", "url": "https://ghe.example/api/v3/repos/org/tool/releases/assets/2"}]},
  {"tag_name": "v9.9.9", "draft": true, "assets": [{"name": "tool-linux-amd64.tar.gz", "url": "https://ghe.example/api/v3/repos/org/tool/releases/assets/3"}]}
]
```

Versions after skip-drafts + reverse: `1.0.0`, `1.2.3`. `find_release(..., "1.2.3")` matches `v1.2.3`. `find_release(..., "9.9.9")` errors (draft).

## Optional checks (no network)

```sh
lua test/ghe_check.lua
luac -p metadata.lua lib/ghe.lua hooks/backend_list_versions.lua hooks/backend_install.lua hooks/backend_exec_env.lua
```
