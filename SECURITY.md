# Security policy

This is a community project (MIT, not affiliated with Google or Anthropic). It
orchestrates the third-party `agy` CLI and runs shell commands on your machine, so
security reports are genuinely appreciated.

## Reporting a vulnerability

**Preferred:** use GitHub's private vulnerability reporting —
**Security → Report a vulnerability** on this repository
(https://github.com/yuting0624/antigravity-for-claude-code/security/advisories/new).
This keeps details private until a fix is available.

If that isn't available to you, open a normal issue describing the impact and a
non-destructive repro, and note that you'd prefer to coordinate privately — a
maintainer will follow up with a private channel.

Please include: affected file/commit, impact (what a malicious/injected input could
do), and a **non-destructive** proof-of-concept (exit codes / policy decisions, not
`rm -rf` — some endpoint security will kill the process on such strings).

## Scope — what matters most here

- **`hooks/validate-delegate-bash.sh`** — the PreToolUse gate that is the *only* thing
  restricting what the `antigravity-delegate` subagent may run via Bash. Bypasses here
  (arbitrary command execution under prompt injection) are the highest-value reports.
- **`scripts/agy-delegate.sh` / `agy-job.sh`** — the wrappers that invoke `agy`.
- **`hooks/`** — anything injected into the model's context or run at session start.
- Trust boundary reminder: `agy` output and repo contents are **untrusted** — the plugin
  treats agy as a tool whose results Claude must verify, never as a trusted authority.

## Not in scope

- Vulnerabilities in the upstream Antigravity CLI (`agy`) itself — report those to
  https://github.com/google-antigravity/antigravity-cli.
- Cost/quota surprises from using `--yolo` or delegating large jobs (documented behavior).

## Supported versions

Fixes land on the latest release. Update with
`/plugin marketplace update antigravity-for-claude-code` and `/reload-plugins`; the
`version` in `.claude-plugin/plugin.json` is what marketplace update recognizes.
