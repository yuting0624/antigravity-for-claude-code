#!/usr/bin/env bash
#
# PostToolUse hook for the delegation server's tools: join Claude's session id with
# the server's per-call usage into one local JSONL line, so the two sides of a
# delegation can be measured together (measure-session.py --join reads it).
#
# Counts only — the digest text is not recorded. Off when no log path is set and the
# default location is not writable. Never fails the tool call (always exits 0).
#
set -uo pipefail
LOG="${CLAUDE_PLUGIN_OPTION_USAGE_LOG:-${ANTIGRAVITY_USAGE_LOG:-$HOME/.antigravity-usage.jsonl}}"
# Read the hook payload first: the heredoc below becomes python's stdin.
HOOK_JSON="$(cat 2>/dev/null || true)"
export HOOK_JSON
python3 - "$LOG" <<'PY' 2>/dev/null
import json, os, re, sys, time
log = sys.argv[1]
try:
    hook = json.loads(os.environ.get("HOOK_JSON", ""))
except Exception:
    sys.exit(0)
tool = hook.get("tool_name", "")
resp = hook.get("tool_response")
texts = []
if isinstance(resp, dict):
    for c in resp.get("content", []) or []:
        if isinstance(c, dict) and c.get("type") == "text":
            texts.append(c.get("text", ""))
elif isinstance(resp, str):
    texts.append(resp)
elif isinstance(resp, list):
    for c in resp:
        if isinstance(c, dict) and c.get("type") == "text":
            texts.append(c.get("text", ""))
body = "\n".join(texts)
usage = None
for m in re.finditer(r"```json\s*(\{.*?\})\s*```", body, re.S):
    try:
        obj = json.loads(m.group(1))
    except Exception:
        continue
    if isinstance(obj, dict) and isinstance(obj.get("usage"), dict):
        usage = obj["usage"]; kind = obj.get("kind"); stats = obj.get("stats") or {}
        break
entry = {
    "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    "claude_session_id": hook.get("session_id"),
    "tool": tool.split("__")[-1] if tool else None,
    "mcp_tool": tool or None,
}
if usage:
    for k in ("input_tokens", "output_tokens", "cached_tokens", "thinking_tokens", "model", "alias", "driver",
              "endpoint_class", "endpoint_host", "latency_ms", "estimated_cost_usd", "job_id", "session_id", "request_id", "cache_hit"):
        if k in usage:
            entry["server_session_id" if k == "session_id" else k] = usage[k]
    entry["kind"] = kind
    for k in ("files", "est_input_tokens", "chunks", "refs_valid_ratio", "truncated"):
        if k in stats:
            entry["stats_" + k] = stats[k]
else:
    m = re.search(r"error:\s*(\{.*\})", body)
    if m:
        try:
            err = json.loads(m.group(1)); entry["error_code"] = err.get("code"); entry["error_kind"] = err.get("kind"); entry["endpoint_host"] = err.get("host")
        except Exception:
            entry["error_code"] = -1
    else:
        sys.exit(0)  # nothing measurable in this response
try:
    os.makedirs(os.path.dirname(os.path.expanduser(log)), exist_ok=True)
    with open(os.path.expanduser(log), "a") as f:
        f.write(json.dumps(entry) + "\n")
    os.chmod(os.path.expanduser(log), 0o600)
except Exception:
    pass
PY
exit 0
