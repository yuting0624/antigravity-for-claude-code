# Claude Code → Antigravity CLI: layout reference and compatibility matrix

Reference material behind `agy-migrate` / the `migrate-to-antigravity` skill.
Everything below was measured against **Claude Code 2.1.229** and **agy 1.1.12** on
macOS, not read off documentation — several of the behaviours contradict the docs, and
those are called out.

---

## 1. Claude Code storage

Two roots, relocated together by `CLAUDE_CONFIG_DIR`. `.claude.json` sits *beside* the
default `~/.claude`, but *inside* a relocated dir.

| Asset | Path | Format |
| --- | --- | --- |
| User settings | `~/.claude/settings.json` | JSON — `model`, `env`, `effortLevel`, `enabledPlugins`, `theme` |
| Permissions | `~/.claude/settings.local.json`, `<repo>/.claude/settings.local.json` | JSON — `permissions.allow` |
| Global state | `~/.claude.json` | JSON — `projects` keyed by **real absolute path** |
| Auto-memory | `~/.claude/projects/<encoded-cwd>/memory/*.md` + `MEMORY.md` | Markdown + YAML frontmatter |
| User skills | `~/.claude/skills/<name>/SKILL.md` | Markdown + frontmatter |
| Plugins | `~/.claude/plugins/cache/<marketplace>/<plugin>/<version>/` | dir with `.claude-plugin/plugin.json` |
| Marketplaces | `~/.claude/plugins/marketplaces/<name>/` | git clones |
| MCP | `<repo>/.mcp.json`, `~/.claude.json` → `projects.<cwd>.mcpServers` | JSON |
| Sessions | `~/.claude/projects/<enc>/<uuid>.jsonl` (+ `<uuid>/subagents/`) | JSONL |
| Credentials | macOS Keychain (`Claude Code-credentials`) | not on disk |

Things people expect and will not find: `~/.claude/CLAUDE.md`, `~/.claude/memory/`,
`~/.claude/agents/`, `~/.claude/commands/`, `~/.claude/hooks/`, `~/.claude/todos/`
(now `tasks/`). Hooks exist only inside plugins.

**The directory-name encoding is lossy.** `/`, `_` and `.` all become `-`:

```
/Users/x/Documents/GitHub                       -> -Users-x-Documents-GitHub
/Users/x/repo/202602_nano_multi-turn_edit       -> -Users-x-repo-202602-nano-multi-turn-edit
```

So it can only be used forward. `agy-migrate` re-encodes every path in
`~/.claude.json`'s `projects` and matches. Two cases resolve to nothing and are
reported rather than guessed at: a directory that matches no known path (the working
directory was deleted), and one that matches **more than one** — `a_b` and `a/b` both
encode to `a-b`, and filing a repo's memory into a different repo's `.agents/rules/`
would be worse than declining.

## 2. Claude Desktop / Cowork

A separate store — it does not read `~/.claude`.

| Asset | Path | Migratable |
| --- | --- | --- |
| MCP | `~/Library/Application Support/Claude/claude_desktop_config.json` | **yes** |
| Extensions | `…/Claude Extensions/<id>/` (`.mcpb`) | no — bundle format |
| Cowork skills | `…/local-agent-mode-sessions/skills-plugin/<account>/<user>/skills/` | no — server-synced, no local original |
| Cowork sessions | `…/local-agent-mode-sessions/<account>/<user>/*.json` | no |
| Bundled CLI | `…/claude-code/<version>/claude.app` | n/a — it reads `~/.claude` like any CLI |

## 3. Antigravity storage

Root is `~/.gemini/`. `~/.antigravity` does not exist; `~/.antigravity-ide/` is the
IDE's VS Code data folder (extensions), unrelated to agent config.

```
~/.gemini/
├── config/                    shared by agy CLI, Antigravity.app and Antigravity IDE.app
│   ├── mcp_config.json        the only global MCP definition
│   ├── config.json            plugin enable flags + userSettings
│   ├── skills/<name>/SKILL.md
│   ├── skills.json            registers skill dirs in non-standard locations
│   ├── plugins/<name>/{plugin.json,mcp_config.json,hooks.json,rules/,skills/,agents/}
│   └── projects/<uuid>.json
├── antigravity-cli/           agy: settings.json, conversations/*.db, brain/, history.jsonl
├── antigravity/               Antigravity.app (Agent Manager)
├── antigravity-ide/           Antigravity IDE.app
└── jetski/                    legacy codename — leave alone
```

Evidence that `config/` is genuinely shared: all three surfaces cache per-tool schemas
for the *same* six MCP servers under their own `mcp/` dirs, all derived from the one
`config/mcp_config.json`.

Precedence (from agy's bundled `agy-customizations` skill), highest first:
workspace `.agents/` → declared `skills.json`/`plugins.json` → `~/.gemini/config/` →
built-ins → global declared.

## 4. Measured behaviours the docs do not state

| # | Behaviour | Consequence |
| --- | --- | --- |
| 1 | `.agents/rules/*.md` and plugin `rules/*.md` need `trigger: always_on` frontmatter | without it they load **never**, silently |
| 2 | Workspace `.agents/` loads only when the session is bound to an agy project | `AGENTS.md`, `.agents/rules/`, `.agents/skills/` all inert under `default-cli-project` |
| 2b | Registering the project is **not** sufficient for `agy -p` | print mode always uses `antigravity-cli/cache/default_project_id.txt`, never the cwd — headless runs need `--project <id>` |
| 3 | Global `skills.json` does not expand `~/` | entries must be absolute paths |
| 4 | Global `~/.gemini/config/plugins/<n>/rules/` **does** load with no project bound | the only reliable always-on global channel |
| 5 | Rule/workflow files are capped at 12,000 characters | longer memory must be split |
| 6 | Rule discovery stops at the repository root | `.agents/` in a plain parent of several repos is unreachable from inside them |

Reproduction for 1, 2 and 2b: put a rule saying "end every reply with TOKEN" at each
candidate location and run `agy -p "say hi" < /dev/null`, with and without
`--new-project` / `--project <id>`.

**Project file provenance.** The shape `agy-migrate` writes —
`{"id", "name", "projectResources": {"resources": [{"folderUri": "file://<path>"}]},
"updatedAt"}` — was read off files agy itself created via `--new-project`, then
confirmed the other way: a project written by the tool and passed back as
`agy --project <id>` does load that workspace's `.agents/rules/`. The cwd→id map in
each surface's `cache/projects.json` is written too, but it is a cache and print mode
ignores it — which is why the tool reports the id rather than claiming the wiring is
finished.

## 5. `agy plugin import claude`

Real, and broader than its symbols suggest — it reports `skills`, `agents`,
`commands`, `mcpServers`, `hooks`. Three defects matter:

| Defect | Detail |
| --- | --- |
| Discovery | scans `~/.claude/plugins/<name>/.claude-plugin/plugin.json` **one level deep** only, and does not follow symlinks. On Claude Code 2.x (`plugins/cache/<mp>/<plugin>/<ver>/`) it prints `No claude extensions found.` and exits **0** |
| Remote MCP | `{"type":"http","url":"…"}` → `{"command":"","args":null,"cwd":"","env":null}`; the URL is discarded and no `serverUrl` written, producing an entry that fails with `command "" not found on PATH` |
| Hooks | Claude's `{"hooks":{…}}` copied byte-for-byte, with Claude tool names as matchers |

It needs **no authentication**, so it can be driven with a substituted `HOME`. That is
how `agy-migrate` bridges the layout gap: copy the real plugins flat into
`$STAGE/.claude/plugins/<name>`, run `HOME=$STAGE agy plugin import claude`, repair the
output, then merge.

It also leaves `.claude-plugin/`, `commands/` and `.mcp.json` behind in the staged
plugin, and the `commands/*.md` → `skills/<plugin>-cmd-<command>/SKILL.md` conversion
omits `name:` from the frontmatter.

### Hook translation table

Antigravity's `hooks.json` is a map of **named** hooks; Claude's is a single `hooks`
object. Matchers are step-type names (`CORTEX_STEP_TYPE_*` lowercased, prefix removed).

| Claude event | Antigravity | Shape |
| --- | --- | --- |
| `PreToolUse` | `PreToolUse` | grouped (`matcher` + `hooks`) |
| `PostToolUse` | `PostToolUse` | grouped |
| `UserPromptSubmit` | `PreInvocation` | flat list of handlers |
| `Stop` | `Stop` | flat |
| `SessionStart`, `SessionEnd`, `PreCompact`, `Notification`, `SubagentStop` | — | dropped, reported |

| Claude tool | Antigravity |
| --- | --- |
| `Bash` | `run_command` |
| `Read` | `view_file` |
| `Grep` | `grep_search` |
| `Glob` | `find` |
| `LS` | `list_directory` |
| `WebFetch` | `read_url_content` |
| `WebSearch` | `search_web` |
| `Task`, `Agent` | `invoke_subagent` |
| `NotebookEdit` | `edit_notebook` |
| `Write`, `Edit` | `propose_code\|write_blob` (approximate) |

`${CLAUDE_PLUGIN_ROOT}` is never set by Antigravity. Hook commands run with CWD set to
the directory holding `hooks.json`, so it is rewritten to `./`.

## 6. Compatibility matrix

| Claude Code | Antigravity | Method |
| --- | --- | --- |
| `~/.claude/skills/` | read in place | `skills.json` entry (absolute path) |
| plugin `skills/`, `agents/`, `commands/` | `config/plugins/<n>/` | native importer via staging HOME |
| plugin `hooks/hooks.json` | `config/plugins/<n>/hooks.json` | translated (table above) |
| plugin `.mcp.json` | `config/plugins/<n>/mcp_config.json` | importer, then remote entries repaired |
| `CLAUDE.md` | `AGENTS.md` | symlink |
| `projects/<home>/memory/` | `config/plugins/claude-code-memory/rules/` | generated, `trigger: always_on` |
| `projects/<repo>/memory/` | `<repo>/.agents/rules/` | generated + project registration |
| `.mcp.json`, `projects.*.mcpServers`, desktop config | `config/mcp_config.json` | merged, `url`→`serverUrl` |
| `hasTrustDialogAccepted` | `trustedWorkspaces` | direct |
| `permissions.allow` `Bash(...)` | `command(...)` | lossy, widening — proposal only |
| `permissions.allow` `Read/WebFetch/WebSearch/Skill/mcp__*` | — | no equivalent |
| `model`, `effortLevel`, `env` | — | reported, never written |
| `projects/**/*.jsonl` | — | **impossible**, see below |
| `tasks/`, `plans/`, `file-history/`, `jobs/`, `paste-cache/` | — | no counterpart |
| credentials | — | different auth; never copy |

### Why sessions cannot be migrated

Claude Code writes newline-delimited JSON, one object per turn, linked by
`uuid`/`parentUuid`. Antigravity writes one SQLite database per conversation
(`~/.gemini/antigravity-cli/conversations/<uuid>.db`) whose schema is

```sql
CREATE TABLE steps (idx integer, step_type integer, status integer,
                    has_subtrajectory numeric, metadata blob, error_details blob,
                    permissions blob, task_details blob, render_info blob,
                    step_payload blob, step_format …);
```

Every payload is an opaque protobuf blob against internal `exa.*` / `cortex.*` schemas,
alongside `trajectory_meta`, `gen_metadata`, `executor_metadata` and
`parent_references`. There is no public writer and no stable schema, so a converter
would be guesswork that silently corrupts state. The readable
`brain/<id>/.system_generated/logs/transcript.jsonl` is an output log, not an input.
