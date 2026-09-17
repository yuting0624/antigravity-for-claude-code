# Troubleshooting

Symptom first. Everything below is for the 1.0 line (the delegation MCP server); the
0.27 notes about the `agy` CLI live on tag `v0.27.4-agy-final`.

## The delegation tools are not offered at all

`/mcp` in Claude Code should list a server for this plugin. If it does not:

- **Node.js is missing or old.** The `SessionStart` hook prints
  `[antigravity] node is not on PATH` / `is older than 20`. Install Node.js 20+ and restart
  the session.
- **The bundle is missing.** `server/index.js` should be ~5 MB inside the plugin
  directory. `scripts/sync-server.sh --from <gemini-studio-mcp checkout>` or reinstall the
  plugin. `/antigravity:setup` (`delegation-doctor`) reports both.
- **Managed install restricts MCP servers.** With `allowManagedMcpServersOnly`, only the
  server in `managed-mcp.json` starts; the plugin's bundled copy is expected not to. The
  tool names then begin with `mcp__delegation__`, not `mcp__plugin_antigravity_delegation__`.

## `error: {"code":11,"kind":"AUTH",…}`

No usable credential. Direct mode needs Application Default Credentials:
`gcloud auth application-default login`, then `/antigravity:setup`. Behind a gateway,
`DELEGATION_GATEWAY_AUTH` names the credential source (`adc-id-token` needs
`DELEGATION_GATEWAY_AUDIENCE`; `bearer-env` names an environment **variable**, which
must be set where Claude Code is launched).

## `error: {"code":15,"kind":"PERMISSION","host":"…"}`

The destination host is not on the egress allowlist. This is a setting, not a flag:
`DELEGATION_ALLOWED_HOSTS` (or `egress.allowedHosts` in `~/.gemini-mcp/config.json`),
managed by the organisation on managed installs. `/antigravity:setup` prints the current
allowlist. A `PERMISSION` without a `host` and with a `root` means the selection root is
outside `DELEGATION_ALLOWED_ROOTS`.

## `error: {"code":14,"kind":"MODEL",…}`

The alias's model is not served to this project (or the gateway does not know the alias).
`/antigravity:setup` shows what each alias resolves to and whether it answered. Change the
alias table (`DELEGATION_ALIAS_INGEST` etc., or `aliases` in the config), not the tool call.

## The digest is truncated / "cut to the token budget"

`token_budget` defaults to 4000 tokens on purpose (it is what Claude carries on every later
turn). Ask a narrower question, split the selection, or raise `token_budget` deliberately
(max 8000). `stats.truncated: true` tells you it happened.

## `refs_valid_ratio` is low

The model produced references that do not point at lines in the selection. Narrow `paths`,
ask a more specific question, or use `alias: "review"`. Do not act on a digest with a
ratio below ~0.9 without opening the references.

## A `digest_codebase` selection is empty or missing files

Inside a git repository the selection is `git ls-files` (tracked + untracked, minus
ignored). Files under `dist/`, `node_modules/`, lockfiles, `.env*`, keys, and files over
512 KB are excluded by the built-in list; binaries and media are listed under
`stats.skipped`. Use `include` / `exclude` patterns, or `digest` for media and PDFs.

## Background job stuck or gone

- `job_status` with no id lists jobs for the **current directory**; `all: true` lists
  every directory.
- An in-process job from a previous server process cannot be resumed: after a restart it is
  marked `failed` with `"server restarted"`. Re-run it.
- A **batch** job lives in Vertex; `job_status` polls it. Minutes to hours is normal.
  `job_cancel` cancels it on Vertex and removes the staged input.
- Registry: `~/.antigravity-jobs/<id>/` (`DELEGATION_JOBS_DIR`).

## `endpoint: external (…)` on every response

Your configuration points at a passthrough proxy or a gateway; the line names its host.
It is a statement of fact, not a warning. `endpoint: geap (…)` means a Google-managed
endpoint.

## Cloud Logging says `off (no permission to write logs…)`

Direct mode writes per-call usage to Cloud Logging in the project when the credential has
`roles/logging.logWriter`. Without it the server keeps the local ledger only; nothing else
changes. Behind a gateway the gateway records instead (`off (a gateway is configured…)`).

## Measuring

`scripts/measure-session.py <session-id> --join` prints the Claude side (exact, from the
transcript) and the delegation side (from `~/.antigravity-usage.jsonl`, written by the
`PostToolUse` hook) of one session together. If the delegation side is empty, check the
`usage_log` plugin option and that the hook is wired (`hooks/hooks.json`).

## Updating

```
/plugin update antigravity@antigravity-for-claude-code
/antigravity:setup
```
The doctor reports the shipped server version against `serverVersion` in `plugin.json`.

## Still stuck?

Open an issue with the output of `/antigravity:setup` and the `error:` envelope line —
never the digest text of anything confidential.
