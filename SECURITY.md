# Security policy

This is a community project (MIT, not affiliated with Google or Anthropic). It ships a
local MCP server that reads files on your machine and sends their text to a model
endpoint, so security reports are genuinely appreciated.

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

- **The delegation server's containment** (`server/index.js`, built from
  [gemini-studio-mcp](https://github.com/yuting0624/gemini-studio-mcp)): a way to read
  outside the selection `root` / `DELEGATION_ALLOWED_ROOTS`, to send to a host outside
  `DELEGATION_ALLOWED_HOSTS`, to get file contents back past the output guards, or to make
  the server write. These are the highest-value reports; report them in either repository.
- **`agents/antigravity-delegate.md`** — the subagent's tool list is the reason a delegated
  read cannot inflate Claude's context; it has no Bash, Read, Write or Edit.
- **`hooks/`** — anything injected into the model's context or run at session start, and the
  `PostToolUse` usage log (counts only, never content).
- **`hooks/validate-delegate-bash.sh`** — the 0.x PreToolUse gate. No longer referenced by
  the subagent in 1.0; it stays on disk until the pending advisory is published, and reports
  against it are still welcome for the 0.27 line (tag `v0.27.4-agy-final`).
- Trust boundary reminder: model output and repository contents are **untrusted** — a
  digest is a claim Claude must verify, never a trusted authority.

## Not in scope

- Vulnerabilities in the upstream Antigravity CLI (`agy`) itself — report those to
  https://github.com/google-antigravity/antigravity-cli.
- Cost/quota surprises from using `--yolo` or delegating large jobs (documented behavior).

## Supported versions

Fixes land on the latest release. Update with
`/plugin marketplace update antigravity-for-claude-code` and `/reload-plugins`; the
`version` in `.claude-plugin/plugin.json` is what marketplace update recognizes.
