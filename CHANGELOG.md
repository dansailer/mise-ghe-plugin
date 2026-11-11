# Changelog

All notable changes to this project are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses [Semantic Versioning](https://semver.org).

## [Unreleased]

### Added

- `.tgz`, `.tar`, `.tar.zst` archives and single compressed binaries (`.gz`, `.xz`, `.bz2`, `.zst`) can be installed ([#18](https://github.com/dansailer/mise-ghe-plugin/pull/18)).
- Contributing guide, security policy, changelog, and issue and pull request templates.

### Changed

- Assets are matched by name tokens per OS and architecture; builds for another platform are rejected instead of installed ([#17](https://github.com/dansailer/mise-ghe-plugin/pull/17)).
- Environment tokens are only sent to the host they belong to; `MISE_GHE_TOKEN_HOSTS` and `MISE_GHE_ALLOW_GITHUB_TOKEN` widen that ([#19](https://github.com/dansailer/mise-ghe-plugin/pull/19)).

### Fixed

- Infinite recursion when `gh` resolved to mise's own shim ([#3](https://github.com/dansailer/mise-ghe-plugin/pull/3)).

## [0.1.0]

Initial version: `ghe:org/repo` backend with version listing, install from release assets, and token lookup from the environment or `gh` ([#1](https://github.com/dansailer/mise-ghe-plugin/pull/1), [#2](https://github.com/dansailer/mise-ghe-plugin/pull/2)). Not tagged.

[Unreleased]: https://github.com/dansailer/mise-ghe-plugin/commits/main
