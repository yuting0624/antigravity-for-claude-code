---
description: Migrate an existing Claude Code setup (skills, memory, CLAUDE.md, MCP, plugins, permissions) to the Antigravity CLI.
argument-hint: "[--apply] [--include-repos] [--apply-permissions] [--uninstall]"
---

Migrate this machine's Claude Code configuration to Antigravity (`agy`).

Run the tool in **dry-run first, always**:

`agy-migrate $ARGUMENTS`

Then read the report back to the user, grouped by unit, and explain:

- What will be **linked live** (skills stay in `~/.claude/skills`; Antigravity reads
  them in place via `skills.json`) versus **generated** (memory, MCP, permissions —
  these need a format change, so they become new files).
- Anything marked `⚠`. Do not gloss over these; they are the parts that need a human
  decision. In particular: permissions are only ever written as a *proposal* unless
  `--apply-permissions` is passed, because Claude's allow-list stores whole command
  lines and collapsing them to `command()` prefixes always widens the grant.
- Anything marked `needs-flag`, and the exact flag that would include it.

Only run with `--apply` after the user has seen the dry-run and agreed. Then tell them:

- the backup path the tool printed, and that `agy-migrate --uninstall --apply` reverses it;
- that session history (`~/.claude/projects/*.jsonl`) is **not** migrated and cannot be —
  Antigravity stores conversations as protobuf blobs inside per-conversation SQLite files;
- that workspace rules under `.agents/` only load when the session is bound to an agy
  project, which is why the tool registers repos in `~/.gemini/config/projects/`.

If the user is only asking what *would* move, stop at the dry-run — do not apply.

For the full compatibility matrix and the reasons behind each mapping, read
`docs/MIGRATION.md` in this plugin.
