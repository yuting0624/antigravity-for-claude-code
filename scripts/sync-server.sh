#!/usr/bin/env bash
#
# Bring the delegation server bundle into this plugin.
#
#   scripts/sync-server.sh --from <gemini-studio-mcp checkout>   # copy a local build
#   scripts/sync-server.sh --release <tag> [--repo owner/name]  # download a release asset set
#
# Either way the result is server/{index.js,prices.json,VERSION}, and the VERSION
# must match `serverVersion` in .claude-plugin/plugin.json — tests/run-tests.sh checks.
#
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FROM=""; RELEASE=""; REPO="yuting0624/gemini-studio-mcp"
while [ $# -gt 0 ]; do
  case "$1" in
    --from) FROM="$2"; shift 2 ;;
    --release) RELEASE="$2"; shift 2 ;;
    --repo) REPO="$2"; shift 2 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "sync-server: unknown option $1" >&2; exit 1 ;;
  esac
done
mkdir -p "$ROOT/server"
if [ -n "$FROM" ]; then
  [ -f "$FROM/server/index.js" ] || { echo "sync-server: $FROM has no server/index.js (run npm run bundle there)" >&2; exit 1; }
  cp "$FROM/server/index.js" "$ROOT/server/index.js"
  cp "$FROM/server/prices.json" "$ROOT/server/prices.json"
  cp "$FROM/server/VERSION" "$ROOT/server/VERSION"
elif [ -n "$RELEASE" ]; then
  BASE="https://github.com/$REPO/releases/download/$RELEASE"
  TMP="$(mktemp -d)"
  for f in index.js prices.json VERSION SHA256SUMS; do
    curl -fsSL "$BASE/$f" -o "$TMP/$f" || { echo "sync-server: could not download $f from $BASE" >&2; exit 1; }
  done
  ( cd "$TMP" && (shasum -a 256 -c SHA256SUMS >/dev/null 2>&1 || sha256sum -c SHA256SUMS >/dev/null) ) \
    || { echo "sync-server: checksum mismatch" >&2; exit 1; }
  cp "$TMP/index.js" "$ROOT/server/index.js"; cp "$TMP/prices.json" "$ROOT/server/prices.json"; cp "$TMP/VERSION" "$ROOT/server/VERSION"
  rm -rf "$TMP"
else
  echo "sync-server: pass --from <checkout> or --release <tag>" >&2; exit 1
fi
V="$(cat "$ROOT/server/VERSION")"
python3 - "$ROOT/.claude-plugin/plugin.json" "$V" <<'PY'
import json, sys
p, v = sys.argv[1], sys.argv[2].strip()
d = json.load(open(p))
if d.get("serverVersion") != v:
    d["serverVersion"] = v
    json.dump(d, open(p, "w"), indent=2, ensure_ascii=False); open(p, "a").write("\n")
    print(f"plugin.json serverVersion -> {v}")
else:
    print(f"server {v} in sync")
PY
