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
  restricting what the `antigravity-delegate` subagent may run via Bash. It limits calls
  to bare `agy-delegate` / `agy-job` / `agy-handoff` with no pipeline, blocks raw
  `--settings` (and `--verify` / `--no-verify` on `agy-handoff`), rejects Windows UNC
  (`\\server\share`, `//server/share`), Win32 device (`\\.\`, `\\?\`), and NT object
  (`\??\`, `/??/`) paths before touching the filesystem (`agy 1.5.14` parity, preventing
  outbound SMB/NTLM lookups), and confines `-d` / `--dir` / `--add-dir` (plus file-path
  `--json-schema`) to literal paths without shell/glob metacharacters resolving inside `cwd`.
  Note that `-d` / `--dir` / `--add-dir` confinement bounds which workspace roots `agy`
  mounts — on `agy 1.5.7+` with an active OS terminal sandbox, unflagged `agy` defaults to
  `Auto` mode (approving workspace edits and vetted/sandboxed commands on `1.5.7+`,
  outside-workspace file reads on `1.5.14+`, and outside-workspace VCS-repository or
  additive writes on `1.5.16+`), whereas `--read-only` (and `--allow-url`) injects
  `agentMode: ""`, `allowNonWorkspaceAccess: false`, `toolPermission: "request-review"`,
  and `ask: ["write_file(*)","command(*)"]` (and rejects conflicting `--yolo`, `--settings`,
  or `--mode accept-edits|auto`) to enforce strict workspace read-only scope. When `--yolo`
  is passed (or implied by `agy-handoff`), `--yolo` (`--dangerously-skip-permissions`) still
  grants `agy` machine-wide tool execution (`--sandbox` is not containment; since `agy 1.5.10`,
  the OS terminal sandbox denies access to `~/.config`, `%APPDATA%`, and `~/.git-credentials`
  by default for sandboxed commands, which still does not contain `--yolo` file or network
  actions). Bypasses of the Bash gate itself (arbitrary command execution under prompt
  injection) are the highest-value reports.
- **`scripts/agy-delegate.sh` / `agy-handoff.sh` / `agy-job.sh`** — the wrappers that invoke `agy`.
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
