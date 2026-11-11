# Security policy

## Reporting a vulnerability

Please do **not** open a public issue for security problems.

Report them privately through [GitHub's private vulnerability reporting](https://github.com/dansailer/mise-ghe-plugin/security/advisories/new) ("Report a vulnerability" on the Security tab). Include the plugin version or commit, your mise version, and steps to reproduce. Redact all tokens.

You should get a response within a week. Fixes are released as soon as possible, and the advisory is published after the fix.

## Supported versions

Only the latest release and the `main` branch receive fixes.

## Scope

In scope, for example:

- a token sent to a host it does not belong to, or logged
- a download accepted from an unexpected host or over plain HTTP
- path traversal or command injection through release, asset or tool names

Out of scope: vulnerabilities in the tools you install with the plugin, in mise itself, or in GitHub Enterprise.
