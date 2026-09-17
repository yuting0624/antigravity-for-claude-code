#!/usr/bin/env bash
#
# SessionStart hook: lightweight check that the delegation server this plugin ships
# can start. Warns on stderr but NEVER fails the session (always exits 0). The full
# health check is `delegation-doctor` / `/antigravity:setup` — this one stays fast
# (no network call) so it doesn't slow every session start.
#
set -uo pipefail
# Builtins only until node is known to exist: this runs on every session start.
HERE="${0%/*}"
ROOT="$HERE/.."

if ! command -v node >/dev/null 2>&1; then
  echo "[antigravity] node is not on PATH — the delegation server needs Node.js 20+; delegation tools will not be available." >&2
  exit 0
fi
major="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)"
if [ "${major:-0}" -lt 20 ]; then
  echo "[antigravity] node $(node -v 2>/dev/null) is older than 20 — the delegation server may not start." >&2
fi
if [ ! -f "$ROOT/server/index.js" ]; then
  echo "[antigravity] server bundle missing (server/index.js) — run scripts/sync-server.sh or reinstall the plugin." >&2
fi
exit 0
