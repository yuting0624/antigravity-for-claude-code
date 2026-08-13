---
name: migrate-to-antigravity
description: Move an existing Claude Code setup onto the Antigravity CLI (agy) — user skills, CLAUDE.md, auto-memory, MCP servers, installed plugins, permissions and trusted workspaces. Use when the user says "migrate to Antigravity", "move my Claude Code config to agy", "bring my skills/memory/MCP over", "set up agy like my Claude Code", "agy plugin import claude found nothing", or asks what can and cannot be carried across. Also use to explain the two config layouts, or to reverse a migration.
version: 0.23.0
---

# Migrating Claude Code → Antigravity CLI

Run `agy-migrate` (dry-run) → read the report → `agy-migrate --apply`.
`agy-migrate --uninstall --apply` reverses everything.

The tool treats the Claude Code config dir as **read-only**. The single exception is
an `AGENTS.md` symlink placed beside an existing `CLAUDE.md`, and only under
`--include-repos`.

---

## Where the two products keep things

**Claude Code** — `~/.claude/` plus `~/.claude.json`, relocatable together via
`CLAUDE_CONFIG_DIR`. Two things surprise people: there is usually no
`~/.claude/CLAUDE.md`, and **auto-memory is per project**, under
`~/.claude/projects/<encoded-cwd>/memory/`. The encoding maps `/`, `_` and `.` all to
`-`, so it can only be matched forward (re-encode a known path), never decoded.

**Claude Desktop / Cowork is a separate universe.** It has its own
`~/Library/Application Support/Claude/claude_desktop_config.json` (MCP) and
`Claude Extensions/` (`.mcpb`), and its Cowork skills are server-synced into
`local-agent-mode-sessions/skills-plugin/`, so no local original exists to migrate.
Only `claude_desktop_config.json`'s `mcpServers` is portable, and the tool picks it up.
The bundled `claude-code/<version>/claude.app` inside the desktop app is the ordinary
CLI and does read `~/.claude`.

**Antigravity** — rooted at `~/.gemini/`, not `~/.antigravity`:

| Path | Shared by |
| --- | --- |
| `~/.gemini/config/` — `mcp_config.json`, `skills/`, `plugins/`, `skills.json`, `projects/` | CLI **and** both desktop apps |
| `~/.gemini/antigravity-cli/settings.json` | `agy` only |
| `~/.gemini/{antigravity-cli,antigravity,antigravity-ide}/` — conversations, brain, knowledge | each surface separately |

So customization is shared across surfaces; session state is not.

---

## What moves, and how

| Asset | Mechanism | Notes |
| --- | --- | --- |
| User skills | **live** — `skills.json` entry pointing at `~/.claude/skills` | no copy; edits show up on both sides |
| Installed plugins | native `agy plugin import claude`, run in a staging HOME | output is then repaired (below) |
| `CLAUDE.md` | symlink `AGENTS.md` → `CLAUDE.md` | `--include-repos`; both are plain Markdown |
| Auto-memory | **generated** rules | global → a plugin's `rules/`; per-repo → `<repo>/.agents/rules/` |
| MCP servers | merged + translated into `mcp_config.json` | `url`/`httpUrl` → `serverUrl`, `type` dropped |
| Trusted projects | `trustedWorkspaces` | the one clean settings mapping |
| Permissions | **proposal only** by default | see the warning below |

### Cannot move

Session transcripts. Claude Code writes plain JSONL; Antigravity writes one SQLite
database per conversation whose payloads are opaque protobuf blobs
(`steps.metadata`, `gen_metadata.data`, …). There is no supported writer.
Also unmovable: `tasks/`, `plans/`, `file-history/`, `jobs/`, and credentials
(different auth systems entirely — never copy these).

---

## Four behaviours that will bite you

These are measured against agy 1.1.12, and none of them are documented.

1. **A rule without `trigger: always_on` is silently ignored.** No error, no warning.
   Only bare `AGENTS.md` / `GEMINI.md` are always-on without frontmatter. Migrated
   memory is therefore *rewritten with* frontmatter, never stripped of it.
2. **Workspace `.agents/` only loads when the session is bound to an agy project —
   and registering one is not enough for headless runs.** `agy -p` always uses the id
   in `antigravity-cli/cache/default_project_id.txt` (`default-cli-project` out of the
   box) regardless of cwd. The tool registers each repo and **prints the id**; run
   `agy --project <id>` there, or pick the project in the TUI. Global
   `~/.gemini/config/` loads regardless, which is why global memory goes to a plugin.
3. **`~/` is not expanded in the global `skills.json`.** Entry paths must be absolute.
4. **Rules and workflows are capped at 12,000 characters per file.** Oversized memory
   is split into `-1.md`, `-2.md` parts on paragraph boundaries.

## What the native importer gets wrong

`agy plugin import claude` exists and handles skills, agents, commands, hooks and MCP —
but:

- It only scans `~/.claude/plugins/<name>/` **one level deep**, which no Claude Code
  2.x install matches (plugins live under `plugins/cache/<marketplace>/<plugin>/<version>/`),
  so on a real machine it prints `No claude extensions found.` and exits 0.
  It also does not follow symlinks, so the staging HOME must contain real copies.
- It **destroys remote MCP servers**: `{"type":"http","url":…}` becomes
  `{"command":"","args":null}` — the URL is dropped and no `serverUrl` is written.
- It **copies hooks verbatim**. Antigravity's `hooks.json` is a map of *named* hooks
  (`{"my-hook": {"PreToolUse": [...]}}`), its matchers are step-type names
  (`run_command`, not `Bash`), and it fires only `PreToolUse`, `PostToolUse`,
  `PreInvocation`, `PostInvocation`, `Stop` — `SessionStart`, `SessionEnd`,
  `PreCompact`, `Notification` and `SubagentStop` have no equivalent. `${CLAUDE_PLUGIN_ROOT}` is
  never set, so hook commands referencing it break.

`agy-migrate` runs the importer anyway (so the output tracks Google's format), then
repairs all three and drops the leftovers it copies.

## Permissions widen the grant — always review

Claude's `permissions.allow` stores whole command **lines**, quoted prompts included,
not command prefixes. They cannot map 1:1 onto agy's `command()`, which matches on a
prefix. The tool keeps the executable plus one plain sub-word (`Bash(git diff:*)` →
`command(git diff)`), absorbs redundant prefixes, and drops entries whose executable
position holds a variable or shell metacharacter.

That is strictly a widening. So the result is written to
`~/.gemini/.agy-migrate/proposed-permissions.json` for review, and merged into
`settings.json` only with `--apply-permissions`.

Also not migrated, by design: `model` (no Gemini equivalent for a Claude model id),
`effortLevel` (agy's `--effort` is a per-session flag, `low|medium|high` only), and
`env` (Anthropic/Vertex routing that means nothing to agy).

---

## Flags

| Flag | Effect |
| --- | --- |
| *(none)* | dry-run report |
| `--apply` | perform it; backs up `~/.gemini/config` first |
| `--only` / `--skip` | `plugins,skills,claudemd,memory,mcp,settings` |
| `--include-repos` | write into git repos (`AGENTS.md`, `.agents/rules/`) |
| `--include-orphan-memory` | fold memory whose source directory no longer exists into global rules |
| `--apply-permissions` | actually write the translated allow-list |
| `--no-register-projects` | skip agy project registration (workspace rules then stay inert) |
| `--roots` | scope for `CLAUDE.md` and MCP discovery (default: the project paths recorded in `~/.claude.json`, or `~` if there are none). The desktop app's `claude_desktop_config.json` is global and always included. |
| `--json` | machine-readable plan |
| `--uninstall` | remove what was generated |

Re-running is safe: generated files carry a marker comment, and a file whose marker
you deleted is treated as yours and left alone.
