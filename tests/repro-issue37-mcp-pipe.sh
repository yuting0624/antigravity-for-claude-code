#!/usr/bin/env bash
# Reproduce issue #37: a stdio-MCP-like child inherits agy's stdout and outlives it.
# The child holds the write end of any capture pipe open -> $(...) never sees EOF.
BIN="$(mktemp -d)"
cat > "$BIN/agy" <<'EOF'
#!/usr/bin/env bash
# Simulate agy: spawn a long-lived "MCP server" child that inherits stdout,
# print the answer, then exit quickly (like real agy: ~6s).
sleep 60 &          # <- the MCP child, inherits our stdout, outlives us
echo "PONG"
exit 0
EOF
chmod +x "$BIN/agy"
export PATH="$BIN:$PATH"

echo "--- BEFORE (command substitution, as shipped) ---"
start=$(date +%s)
timeout 10 bash -c 'OUT="$(agy -p "ping" </dev/null 2>/dev/null)"; echo "got:[$OUT]"'
rc=$?
echo "rc=$rc elapsed=$(( $(date +%s) - start ))s $( [ $rc -eq 124 ] && echo '<-- HUNG (killed at 10s)' )"

echo "--- AFTER (temp file, the fix) ---"
start=$(date +%s)
timeout 10 bash -c 'F="$(mktemp)"; agy -p "ping" </dev/null >"$F" 2>/dev/null; OUT="$(cat "$F")"; rm -f "$F"; echo "got:[$OUT]"'
rc=$?
echo "rc=$rc elapsed=$(( $(date +%s) - start ))s $( [ $rc -eq 0 ] && echo '<-- RETURNED' )"
rm -rf "$BIN"
