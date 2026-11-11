#!/usr/bin/env bash
# End-to-end smoke test: install tools through this plugin with an isolated mise.
#
#   test/smoke.sh 'ghe:BurntSushi/ripgrep@14.1.1=rg' 'ghe:cli/cli@2.63.0=gh'
#
# Each argument is <tool@version>=<binary>; the binary must answer --version.
# The API defaults to public github.com, so no GitHub Enterprise is needed. Set
# MISE_GHE_TOKEN (e.g. to the Actions token) to avoid anonymous rate limits.
set -euo pipefail

if [ "$#" -eq 0 ]; then
    echo "usage: $0 'ghe:org/repo@version=binary' ..." >&2
    exit 2
fi

root="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# mise on Windows is a native program; hand it Windows paths under Git Bash.
native_path() {
    if command -v cygpath >/dev/null 2>&1; then
        cygpath -w "$1"
    else
        printf '%s\n' "$1"
    fi
}

for dir in config system data cache state project; do
    mkdir -p "$tmp/$dir"
done
MISE_CONFIG_DIR="$(native_path "$tmp/config")"
MISE_SYSTEM_CONFIG_DIR="$(native_path "$tmp/system")"
MISE_GLOBAL_CONFIG_FILE="$(native_path "$tmp/config/config.toml")"
MISE_DATA_DIR="$(native_path "$tmp/data")"
MISE_CACHE_DIR="$(native_path "$tmp/cache")"
MISE_STATE_DIR="$(native_path "$tmp/state")"
MISE_GHE_API_URL="${MISE_GHE_API_URL:-https://api.github.com}"
MISE_YES=1
export MISE_CONFIG_DIR MISE_SYSTEM_CONFIG_DIR MISE_GLOBAL_CONFIG_FILE MISE_DATA_DIR
export MISE_CACHE_DIR MISE_STATE_DIR MISE_GHE_API_URL MISE_YES

cd "$tmp/project"
mise --version
mise plugins link ghe "$(native_path "$root")"

for spec in "$@"; do
    tool="${spec%=*}"
    bin="${spec##*=}"
    echo "::group::$tool"
    mise install "$tool"
    mise exec "$tool" -- "$bin" --version
    echo "::endgroup::"
done
echo "smoke: ok"
