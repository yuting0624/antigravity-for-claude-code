# 0.27 → 1.0: from the `agy` CLI to the delegation MCP server

1.0 replaces the transport and narrows the job. Nothing you did with 0.x is silently
reinterpreted: what maps, maps below; what does not, is listed with the reason.

## What changed, in one table

| 0.27 | 1.0 | Note |
|---|---|---|
| `agy-delegate --dir . --digest "…"` | `digest_codebase({ paths, root, question })` | reading only; files never enter context |
| `agy-delegate --yolo --dir . "implement / scaffold / migrate …"` | **not ported** | the server never writes; do it with Claude, or delegate the *reading* that precedes it |
| `git diff \| agy-delegate --tier pro -` (`/antigravity:review`) | `review_diff({ root, range?, paths?, adversarial? })` | server runs `git diff`; findings anchored to `path:line`; a different model family |
| `agy-job start / status / result / cancel` | `async: true` → `job_status` / `job_result` / `job_cancel` | same registry layout under `~/.antigravity-jobs/`, same `rc` words |
| `agy-media <file>` (`/antigravity:media`) | `digest({ file_paths })` | timestamped / cited digest; `save_transcript` writes the file |
| `agy-delegate --tier flash-lo\|flash\|pro` | alias `cheap` / `ingest` / `review` | aliases resolve in the server's config (or the organisation's gateway), not on each machine |
| `--model`, `default_model`, `tier_*` options | alias table in `~/.gemini-mcp/config.json` / `managed-mcp.json` | model choice is a setting the organisation owns |
| `AGY_USAGE` line on stderr, `AGY_USAGE_LOG` | `usage:` / `offload:` / `endpoint:` footer, server ledger, `usage_log` hook | `measure-session.py --join <log>` puts both sides together |
| exit codes `10 11 12 13 14 15 2 3` | `error: {"code":N,"kind":"…","retry":bool}` envelope | same numbers, now with `host` for egress refusals |
| `agy-doctor` (`/antigravity:setup`) | `delegation-doctor` | node, bundle version, then the server's `health_check` (auth, gateway, egress, aliases) |
| `agy-trace --audit` | `stats` on every response (`refs_valid_ratio`, `elided_runs`, `redactions`, `truncated`) | no executor trajectory exists; the guards report instead |
| `agy-cost-compare` | `savings_report` | totals from the ledger, per tool / alias / destination |
| internal fan-out (`define_subagent`) | **not ported** | no agent loop on the cheap side; batch jobs cover the "many parts" case |
| `/antigravity:research` fan-out on agy | `search_web` (Google Search grounding on Vertex AI) | one call per sub-question; dated, URL-cited findings and the sources used; vertex driver only |
| `default_model` pointing at a Claude model in agy | alias model `anthropic/<model>` | Claude on Vertex AI through the same project and proxy; the family switch stays inside GEAP |
| `--sandbox`, `--continue`, `--mode`, `permissions.allow write_file(...)` | gone | nothing to grant: the server only reads, under `root` |
| `hooks/validate-delegate-bash.sh` PreToolUse gate | unreferenced | the subagent has no Bash; the file stays until advisory #61 is published |

## Prerequisites

- **Node.js 20+** on PATH. The server ships inside the plugin (`server/index.js`); there
  is nothing else to install. `/antigravity:setup` checks.
- **Credentials:** Application Default Credentials for a Google Cloud project with Vertex
  AI enabled (`gcloud auth application-default login`), *or* the organisation's gateway
  credential when the server is configured for a gateway.
- The `agy` CLI is no longer used or checked. `/antigravity:migrate` (moving a Claude Code
  setup onto agy) is unrelated to the transport and still ships.

## Where settings live now

Plugin options are down to three Conductor-side switches (`coding_policy`,
`delegation_nudge`, `usage_log`). Everything about *where requests go* is the server's:

- Self-serve: `~/.gemini-mcp/config.json` (or environment variables). Example:
  ```json
  { "gateway": { "driver": "vertex" }, "projectId": "my-gcp-project" }
  ```
- Managed: `managed-mcp.json` deployed by the organisation (see `deploy/`). Developers
  cannot widen the egress allowlist or move the alias table from their own machine.

Every key is documented in the server's README (`gemini-studio-mcp`): drivers
(`vertex` direct, Vertex passthrough via `gateway.baseUrl`, `openai-compat`), the alias
table, `egress.allowedHosts`, `codebase.allowedRoots`, jobs, caching, telemetry.

## Verifying the install

```
/antigravity:setup
```
Expect: node ≥ 20, `server bundle 0.3.0`, then the server's diagnosis with `Gateway`,
`Egress`, one line per alias (`ingest`, `review`, `cheap`) naming the model that
answered, and `Cloud Logging`. Then, in a repository:

```
/antigravity:delegate Where is configuration loaded, and which env vars override it? src
```
Expect a digest with `file:line` references, a stats line reporting `refs_valid_ratio`,
and a footer ending in `endpoint: geap (aiplatform.googleapis.com)` (or your gateway's
host).

## Things that look like bugs and are not

- **The subagent "has no Bash".** Intentional. Its only tools are the server's, which is
  what guarantees the bulky read cannot end up in its context.
- **A digest was "cut to the token budget".** `token_budget` defaults to 4000 tokens
  because that is what you carry on every later turn. Ask a narrower question, or raise
  it deliberately.
- **`endpoint: external (…)`** on every call. Your organisation configured a passthrough
  proxy or a gateway; the line names its host. It is a fact, not a warning.
- **PERMISSION (15) naming a host.** The destination is outside the egress allowlist.
  Adding it is an organisation decision (`DELEGATION_ALLOWED_HOSTS`), not a flag.
- **A batch job that "takes forever".** Batch is minutes to hours with no completion-time
  guarantee; it exists for selections above the interactive limit. `job_status` shows the
  Vertex state; `job_cancel` stops it.
