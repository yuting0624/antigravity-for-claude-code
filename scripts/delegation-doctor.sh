#!/usr/bin/env bash
#
# Health check for the delegation server this plugin ships: is node new enough,
# is the bundle present and the version the plugin expects, and what does the
# server itself say about auth, gateway, egress and models. Read-only.
#
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SERVER="$ROOT/server/index.js"
rc=0

if ! command -v node >/dev/null 2>&1; then
  echo "❌ node is not on PATH. The delegation server needs Node.js 20 or newer." >&2
  exit 13
fi
NODE_MAJOR="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)"
if [ "$NODE_MAJOR" -lt 20 ]; then
  echo "❌ node $(node -v) is too old; the delegation server needs 20 or newer." >&2
  rc=13
else
  echo "✅ node $(node -v)"
fi

if [ ! -f "$SERVER" ]; then
  echo "❌ server bundle missing at $SERVER — run scripts/sync-server.sh (or reinstall the plugin)." >&2
  exit 13
fi
SHIPPED="$(cat "$ROOT/server/VERSION" 2>/dev/null || echo unknown)"
EXPECTED="$(python3 -c "import json;print(json.load(open('$ROOT/.claude-plugin/plugin.json')).get('serverVersion','?'))" 2>/dev/null || echo '?')"
if [ "$SHIPPED" = "$EXPECTED" ]; then
  echo "✅ server bundle $SHIPPED"
else
  echo "⚠️  server bundle is $SHIPPED but the plugin expects $EXPECTED — run scripts/sync-server.sh."
fi

echo
echo "── server health_check ──"
node "$SERVER" --cli health_check "$@" 2> >(grep -v MetadataLookup >&2) || rc=$?
exit "$rc"
