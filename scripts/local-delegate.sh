#!/usr/bin/env bash
#
# local-delegate.sh — headless wrapper around any OpenAI-compatible LOCAL model server
# (Ollama · LM Studio · llama.cpp server · vLLM · llama-swap · …).
# Part of the "Antigravity for GLM Code" plugin: the LOCAL executor.
#
# Purpose: let the conductor (GLM, running in the pi coding agent) hand a
# well-scoped subtask to a LOCAL model via POST {base}/v1/chat/completions, and get
# clean text back on stdout — same contract as agy-delegate.sh, same exit codes.
#
# What a LOCAL executor is, honestly:
#   * it is a plain chat-completion call. No agent loop, no terminal, no MCP.
#   * it CANNOT read your workspace — do not pass --dir and expect file access;
#     feed content via stdin (`cat file | local-delegate -`) instead.
#   * it CANNOT write files either — the model only returns text. The wrapper can
#     write that text for you with `--out <file>` (the model generates, the wrapper
#     writes; safe by construction, nothing executes).
#   * `--web` gives it search: the WRAPPER fetches results (SearXNG JSON API if
#     configured, else DuckDuckGo Lite HTML) and hands them to the model as context.
#     The query does leave your machine to reach the search engine; the synthesis
#     stays local.
#   * everything runs on your machine (except --web's fetch) — private, free,
#     offline-capable. The tradeoff is capability: pick tasks a 7–32B model can do.
#
# Usage:
#   local-delegate.sh [options] "the task prompt"
#   echo "long prompt" | local-delegate.sh [options] -     # read prompt from stdin
#
# Options:
#   -t, --tier <fast|think>        Local tier (default: fast). Aliases accepted from
#                                  the agy side: flash|flash-lo -> fast, pro -> think.
#   -m, --model <exact name>       Exact model name on the server (overrides tier;
#                                  e.g. qwen2.5-coder:7b, llama3.1:8b, glm-4.6-gguf)
#       --host <base-url>          Server base URL (default http://localhost:11434/v1
#                                  for Ollama; LM Studio http://localhost:1234/v1).
#                                  A bare host:port gets "/v1" appended automatically.
#       --timeout <dur>            Wall-clock timeout, e.g. 10m (default: 10m — local
#                                  inference on large models is slower than an API).
#       --digest                   Append a digest-only output contract to the prompt
#                                  (ingest digests, not raw dumps — the biggest cost
#                                  lever, and it keeps the conductor's context lean).
#       --out <file>               Write the model's reply to <file> instead of stdout
#                                  (single outer code fence is unwrapped; --raw keeps
#                                  the reply verbatim). This is the "execution" path.
#       --raw                      With --out: do NOT unwrap an outer code fence.
#       --web                      Fetch search results first (SearXNG if
#                                  LOCAL_SEARXNG_URL / searxng_url is set, else
#                                  DuckDuckGo Lite) and pass them as context.
#       --print-command            Print the resolved curl command and exit (dry run)
#   -h, --help                     Show this help
#
# Accepted-and-ignored (compat with agy-delegate passthrough; each warns on stderr):
#   --yolo --sandbox --mode <m> --continue --conversation <id> --dir <path> --backend <b>
#   A local model executes nothing, so permission flags have no effect here.
#
# Exit codes: 0 ok | 1 usage | 2 server/HTTP failure | 3 empty reply | 10 rate limit
#             | 11 auth required (bad API key) | 12 timeout | 13 server not reachable
#             | 14 model not found on the server
#             (mirrors agy-delegate.sh so agy-job.sh labels work for both)
#
# On a classifiable failure, a machine-readable line goes to stderr:
#   LOCAL_SIGNAL {"status":"...","reason":"...","model":"..."}
# On success, token usage (when the server reports it) goes to stderr:
#   LOCAL_USAGE {"backend":"local","model":"...","input":N,"output":N,"total":N}
#
# Configuration precedence: CLI flag > env (LOCAL_DELEGATE_*) > plugin userConfig
# (CLAUDE_PLUGIN_OPTION_*) > built-in default.
#   base URL:  --host > LOCAL_DELEGATE_BASE_URL > CLAUDE_PLUGIN_OPTION_LOCAL_BASE_URL
#              > http://localhost:11434/v1
#   API key:   LOCAL_DELEGATE_API_KEY > CLAUDE_PLUGIN_OPTION_LOCAL_API_KEY > (none).
#              Ollama needs no key; vLLM/LM Studio accept any; set one for gated servers.
#   tiers:     CLAUDE_PLUGIN_OPTION_LOCAL_TIER_FAST (default qwen2.5-coder:7b)
#              CLAUDE_PLUGIN_OPTION_LOCAL_TIER_THINK (default qwen3:14b)
#   web:       LOCAL_SEARXNG_URL > CLAUDE_PLUGIN_OPTION_SEARXNG_URL > DuckDuckGo Lite
#
set -euo pipefail

# --- option aliasing ----------------------------------------------------------
# pi-package era: prefer the shorter AGY_OPTION_* names. The historical
# CLAUDE_PLUGIN_OPTION_* names keep working (upstream scripts/tests use them);
# when both are set the legacy name wins. Values may contain spaces.
_agy_alias() {
  _o="$1"
  eval "_v=\"\${AGY_OPTION_$_o:-}\""
  if [ -n "$_v" ]; then
    eval "current=\"\${CLAUDE_PLUGIN_OPTION_$_o:-}\""
    [ -n "$current" ] || eval "export CLAUDE_PLUGIN_OPTION_$_o=\"$_v\""
  fi
  unset _o _v current
}
for _agy_opt in DEFAULT_TIER TIMEOUT TIER_FLASH TIER_FLASH_LO TIER_PRO DEFAULT_MODEL \
                EXECUTOR_BACKEND USAGE_LOG STRUCTURED_OUTPUT DIGEST_WARN_CHARS \
                CODING_POLICY DELEGATION_NUDGE LOCAL_BASE_URL LOCAL_MODEL \
                LOCAL_TIER_FAST LOCAL_TIER_THINK LOCAL_API_KEY SEARXNG_URL LOCAL_TIMEOUT; do
  _agy_alias "$_agy_opt"
done
unset _agy_alias _agy_opt

TIER=""
MODEL=""
BASE=""
# Local secrets stay OUT of this repo: keys are read from the environment or from
# an untracked local env file (default ~/.config/antigravity-for-glm/env, chmod 600) —
# never hardcoded in tracked files.
LOCAL_ENV_FILE="${LOCAL_DELEGATE_ENV_FILE:-$HOME/.config/antigravity-for-glm/env}"
[ -r "$LOCAL_ENV_FILE" ] && . "$LOCAL_ENV_FILE"
API_KEY="${LOCAL_DELEGATE_API_KEY:-${CLAUDE_PLUGIN_OPTION_LOCAL_API_KEY:-}}"
# Defaults target THIS machine's omlx engine (MLX, Apple Silicon) serving
# Ornith-1.5-35B-A3B-MLX-4bit. Override any of them via env for other engines.
TIMEOUT="${CLAUDE_PLUGIN_OPTION_LOCAL_TIMEOUT:-10m}"
DIGEST=0
OUT_FILE=""
RAW=0
WEB=0
PRINT_CMD=0
PROMPT=""

die() { echo "local-delegate: $*" >&2; exit 1; }
need() { [ "$1" -ge 2 ] || die "option '$2' needs a value"; }

usage() { sed -n '/^# Usage:/,/^# Configuration precedence/p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

# Machine-readable failure signal (same shape as agy-delegate's AGY_SIGNAL).
signal() {
  local status="$1" reason="$2" line
  reason="$(printf '%s' "$reason" | tr '\n\r\t' '   ' | tr -d '"\\' | cut -c1-200)"
  line="$(printf 'LOCAL_SIGNAL {"status":"%s","reason":"%s","model":"%s"}' \
    "$status" "$reason" "${MODEL:-}")"
  printf '%s\n' "$line" >&2
}

# Map a tier name to a local model. agy-style aliases (flash/pro) are accepted so
# `agy-delegate --backend local` can pass its tier through unchanged.
model_for_tier() {
  case "$1" in
    fast)  echo "${AGY_OPTION_LOCAL_TIER_FAST:-${CLAUDE_PLUGIN_OPTION_LOCAL_TIER_FAST:-Ornith-1.5-35B-A3B-MLX-4bit}}" ;;
    think) echo "${AGY_OPTION_LOCAL_TIER_THINK:-${CLAUDE_PLUGIN_OPTION_LOCAL_TIER_THINK:-Ornith-1.5-35B-A3B-MLX-4bit}}" ;;
    *) die "unknown tier '$1' (use fast | think)" ;;
  esac
}

# Normalize a tier alias to fast|think.
norm_tier() {
  case "$1" in
    fast|flash|flash-lo) echo fast ;;
    think|pro)           echo think ;;
    *) die "unknown tier '$1' (use fast | think)" ;;
  esac
}

# Duration (5m / 300s / 1h / bare number) -> whole seconds for curl --max-time.
dur_secs() {
  local d="${1:-10m}" n unit
  n="${d%[smh]}"; unit="${d#"$n"}"
  case "$n" in (*[!0-9]*|'') n=600; unit=s ;; esac
  case "$unit" in
    h) echo $(( n * 3600 )) ;;
    m) echo $(( n * 60 )) ;;
    *) echo "$n" ;;
  esac
}

# Resolve the base URL: flag > env > plugin option > Ollama default. A URL with no
# path (scheme://host[:port]) gets "/v1" appended — every OpenAI-compatible server
# serves chat under /v1, and "localhost:11434" is what people type first.
resolve_base() {
  local b="${1:-}"
  [ -n "$b" ] || b="${LOCAL_DELEGATE_BASE_URL:-${CLAUDE_PLUGIN_OPTION_LOCAL_BASE_URL:-http://127.0.0.1:8000/v1}}"
  b="${b%/}"
  case "$b" in
    */v[0-9]*) : ;;
    *)
      # no /vN path segment anywhere -> append /v1 (bare host:port form)
      case "$b" in
        *://*/?*) : ;;               # has some path already; leave it alone
        *) b="$b/v1" ;;
      esac ;;
  esac
  echo "$b"
}

while [ $# -gt 0 ]; do
  case "$1" in
    -t|--tier)      need "$#" "$1"; TIER="$2"; shift 2 ;;
    -m|--model)     need "$#" "$1"; MODEL="$2"; shift 2 ;;
        --host)     need "$#" "$1"; BASE="$2"; shift 2 ;;
        --timeout)  need "$#" "$1"; TIMEOUT="$2"; shift 2 ;;
        --digest)   DIGEST=1; shift ;;
        --out)      need "$#" "$1"; OUT_FILE="$2"; shift 2 ;;
        --raw)      RAW=1; shift ;;
        --web)      WEB=1; shift ;;
        --print-command) PRINT_CMD=1; shift ;;
    -h|--help)      usage ;;
    -)              PROMPT="$(cat)"; shift ;;
    --)             shift; PROMPT="${*:-}"; break ;;
    # ---- agy-delegate passthrough compat: accept, warn, ignore ----
    --yolo)         echo "local-delegate: note: --yolo has no effect on the local backend — a chat-completion call executes nothing." >&2; shift ;;
    --sandbox)      echo "local-delegate: note: --sandbox has no effect on the local backend — nothing executes locally besides this curl call." >&2; shift ;;
    --mode)         need "$#" "$1"; echo "local-delegate: note: --mode '$2' has no effect on the local backend." >&2; shift 2 ;;
    --continue)     echo "local-delegate: note: --continue has no effect on the local backend — each call is stateless. Put the full context in the prompt." >&2; shift ;;
    --conversation) need "$#" "$1"; echo "local-delegate: note: --conversation has no effect on the local backend — calls are stateless." >&2; shift 2 ;;
    -d|--dir)       need "$#" "$1"; echo "local-delegate: note: the local backend cannot read '$2' — it has no file access. Paste content via stdin ('-' prompt) instead, or use the agy backend for agentic file work." >&2; shift 2 ;;
        --backend)  need "$#" "$1"; shift 2 ;;   # consumed by the dispatcher already; ignore
    -*)             die "unknown option '$1'" ;;
    *)              PROMPT="$*"; break ;;
  esac
done

[ -n "$PROMPT" ] || die "no prompt given (pass a string, or '-' to read stdin)"

BASE="$(resolve_base "$BASE")"

# omlx requires a Bearer key even on loopback; it is deliberately NOT hardcoded
# here (secrets never live in tracked files). Set LOCAL_DELEGATE_API_KEY via env or
# the local env file above. Other engines (Ollama ignores auth entirely; LM Studio/
# vLLM usually keyless) need no header.
if [ -z "$API_KEY" ]; then
  case "$BASE" in
    http://127.0.0.1:8000/*|http://localhost:8000/*)
      echo "local-delegate: warning: $BASE looks like an omlx endpoint, which needs LOCAL_DELEGATE_API_KEY (not set)" >&2
      echo "local-delegate:   fix: printf 'export LOCAL_DELEGATE_API_KEY=<key>\\n' >> ~/.config/antigravity-for-glm/env && chmod 600 ~/.config/antigravity-for-glm/env" >&2
      ;;
  esac
fi

# Resolve the model: --model > explicit --tier > plugin default_model > tier fast.
if [ -z "$MODEL" ]; then
  if [ -n "$TIER" ]; then
    TIER="$(norm_tier "$TIER")"
    MODEL="$(model_for_tier "$TIER")"
  elif [ -n "${CLAUDE_PLUGIN_OPTION_LOCAL_MODEL:-}" ]; then
    MODEL="$CLAUDE_PLUGIN_OPTION_LOCAL_MODEL"
  else
    MODEL="$(model_for_tier fast)"
  fi
fi

# --digest: the same digest-only output contract agy-delegate appends (issue #5 —
# the single biggest cost lever is ingesting digests, not raw dumps).
if [ "$DIGEST" -eq 1 ]; then
  PROMPT="$PROMPT

OUTPUT CONTRACT (digest): reply with ONLY a compact digest - short bullets (findings / decisions / errors, with file:line references where useful). NO full file contents, NO raw logs, NO long code blocks. End with exactly one line: DIGEST: <one-sentence summary>."
fi

command -v curl >/dev/null 2>&1 || { signal BACKEND_MISSING "curl not found — the local executor talks HTTP via curl"; exit 13; }
command -v python3 >/dev/null 2>&1 || die "python3 required (JSON build/parse) — it is a plugin dependency"

# One trap for every temp file this script creates.
REQF=""; RESPF=""; CODEF=""; WEBRAW=""; WEBCTX=""; PROMPTF=""
trap 'rm -f "$REQF" "$RESPF" "$CODEF" "$WEBRAW" "$WEBCTX" "$PROMPTF" 2>/dev/null' EXIT
PROMPTF="$(mktemp "${TMPDIR:-/tmp}/local-delegate-prompt.XXXXXX")"
printf '%s\n' "$PROMPT" >"$PROMPTF"

# --- optional web legwork: WRAPPER fetches, LOCAL model synthesizes ----------------
# The model cannot browse; we can. Results are handed over as numbered context with
# an explicit citation instruction, and the caveat is honest: if 0 results come back
# we warn and let the model answer from its own knowledge — which is UNVERIFIED.
if [ "$WEB" -eq 1 ]; then
  WEBRAW="$(mktemp "${TMPDIR:-/tmp}/local-delegate-web.XXXXXX")"
  WEBCTX="$(mktemp "${TMPDIR:-/tmp}/local-delegate-webctx.XXXXXX")"
  SEARX="${LOCAL_SEARXNG_URL:-${CLAUDE_PLUGIN_OPTION_SEARXNG_URL:-}}"
  Q="$(printf '%s' "$PROMPT" | tr '\n' ' ' | cut -c1-300)"
  WEB_ERR=""
  if [ -n "$SEARX" ]; then
    SEARX="${SEARX%/}"
    curl -sS --max-time 20 -G --data-urlencode "q=$Q" --data-urlencode "format=json" \
      "$SEARX/search" >"$WEBRAW" 2>/dev/null || WEB_ERR="searxng fetch failed"
  else
    # DuckDuckGo Lite: no API key, stable-enough HTML. Best-effort by design.
    curl -sS --max-time 20 -G --data-urlencode "q=$Q" \
      -A "Mozilla/5.0 (compatible; local-delegate/0.26)" \
      "https://lite.duckduckgo.com/lite/" >"$WEBRAW" 2>/dev/null || WEB_ERR="duckduckgo fetch failed"
  fi
  N_RES="$(LD_SRC="$WEBRAW" LD_DST="$WEBCTX" LD_SEARX="$SEARX" python3 - <<'PY' 2>/dev/null || echo 0
import html, json, os, re, sys

src, dst = os.environ["LD_SRC"], os.environ["LD_DST"]
rows = []
try:
    raw = open(src, encoding="utf-8", errors="replace").read()
except Exception:
    raw = ""
if os.environ.get("LD_SEARX"):
    try:
        for r in json.loads(raw).get("results", [])[:8]:
            t = " ".join(str(r.get("title") or "").split())
            u = str(r.get("url") or "")
            s = " ".join(str(r.get("content") or "").split())[:300]
            if u:
                rows.append((t, u, s))
    except Exception:
        rows = []
else:
    # NOTE: no literal apostrophe may appear in this heredoc body — an unbalanced
    # quote inside $( ... ) breaks bash parsing of the whole script. The quote
    # characters below are written as regex hex escapes (\x22 = double, \x27 = single).
    links = re.findall(
        "<a[^>]*href=\"(https?://[^\"]+)\"[^>]*class=[\x22\x27]result-link[\x22\x27][^>]*>(.*?)</a>",
        raw, re.S | re.I)
    snips = re.findall(
        "class=[\x22\x27]result-snippet[\x22\x27][^>]*>(.*?)</td>", raw, re.S | re.I)
    seen = set()
    for i, (u, t) in enumerate(links):
        if "duckduckgo.com" in u or u in seen:
            continue
        seen.add(u)
        title = html.unescape(re.sub(r"<[^>]+>", "", t)).strip()
        snip = ""
        if i < len(snips):
            snip = html.unescape(re.sub(r"<[^>]+>", "", snips[i])).strip()[:300]
        rows.append((title, u, snip))
        if len(rows) >= 8:
            break
with open(dst, "w", encoding="utf-8") as fh:
    for n, (t, u, s) in enumerate(rows, 1):
        fh.write("[%d] %s\n    %s\n" % (n, u, ("%s — " % t) + s if s else t))
print(len(rows))
PY
)"
  if [ "${N_RES:-0}" -gt 0 ]; then
    printf 'WEB SEARCH RESULTS (fetched live by the wrapper; you cannot browse - use these):\n%s\n' \
      "$(cat "$WEBCTX")" >"$WEBCTX.new" && mv "$WEBCTX.new" "$WEBCTX"
    echo "local-delegate: web: $N_RES results fetched${SEARX:+ (searxng)}${SEARX:- (duckduckgo)}; synthesis stays local; cite [n] + URL." >&2
  else
    echo "local-delegate: note: --web got 0 results (${WEB_ERR:-empty page}) — the model will answer from its own knowledge, which is UNVERIFIED. For reliable grounded search use the agy backend (Gemini web tools)." >&2
    rm -f "$WEBCTX"; WEBCTX=""
  fi
fi

# --- build the request JSON (python owns all escaping; prompt may hold anything) ----
REQF="$(mktemp "${TMPDIR:-/tmp}/local-delegate-req.XXXXXX")"
LD_PROMPT_FILE="$PROMPTF" LD_WEB_FILE="$WEBCTX" LD_MODEL="$MODEL" LD_REQ="$REQF" \
  LD_PRINT="$PRINT_CMD" python3 - <<'PY'
import json, os

prompt = open(os.environ["LD_PROMPT_FILE"], encoding="utf-8").read()
webf = os.environ.get("LD_WEB_FILE") or ""
if webf and os.path.exists(webf):
    ctx = open(webf, encoding="utf-8").read()
    prompt = (ctx + "\n\nQUESTION/TASK:\n" + prompt +
              "\n\nAnswer using the numbered results above. Cite [n] and include the "
              "URL for every claim. If the results do not answer it, say so explicitly "
              "instead of guessing.")
body = {"model": os.environ["LD_MODEL"], "stream": False,
        "messages": [{"role": "user", "content": prompt}]}
with open(os.environ["LD_REQ"], "w", encoding="utf-8") as fh:
    json.dump(body, fh, ensure_ascii=False)
PY
if [ "$PRINT_CMD" -eq 1 ]; then
  # dry run: inline the single-line escaped JSON so the printed command is copy-paste runnable
  printf 'curl -sS --max-time %s -X POST %q -H "Content-Type: application/json"' "$(dur_secs "$TIMEOUT")" "$BASE/chat/completions"
  [ -n "$API_KEY" ] && printf ' -H "Authorization: Bearer <redacted>"'
  printf ' -d %q\n' "$(cat "$REQF")"
  exit 0
fi

# --- call the server ----------------------------------------------------------------
RESPF="$(mktemp "${TMPDIR:-/tmp}/local-delegate-resp.XXXXXX")"
CODEF="$(mktemp "${TMPDIR:-/tmp}/local-delegate-code.XXXXXX")"
SECS="$(dur_secs "$TIMEOUT")"
set +e
CURL_ARGS=(-sS --max-time "$SECS" -X POST "$BASE/chat/completions"
           -H "Content-Type: application/json" -d @"$REQF"
           -o "$RESPF" -w '%{http_code}')
[ -n "$API_KEY" ] && CURL_ARGS+=(-H "Authorization: Bearer $API_KEY")
curl "${CURL_ARGS[@]}" >"$CODEF" 2>/dev/null
CURL_RC=$?
set -e
HTTP_CODE="$(cat "$CODEF" 2>/dev/null || echo 000)"

# curl-level failures first (no HTTP response to classify).
if [ "$CURL_RC" -ne 0 ]; then
  case "$CURL_RC" in
    28) signal TIMEOUT "curl --max-time ${SECS}s reached (local inference can be slow — raise --timeout or use a smaller model)"; exit 12 ;;
    7|6) signal BACKEND_MISSING "cannot reach local server at $BASE — is it running? (ollama serve / LM Studio server / vLLM up)"; exit 13 ;;
     *) signal LOCAL_FAILED "curl exited $CURL_RC contacting $BASE"; exit 2 ;;
  esac
fi

# HTTP-level classification. The error body decides 14 (model) vs 2 (generic).
BODY_LC="$(tr '[:upper:]' '[:lower:]' <"$RESPF" 2>/dev/null || true)"
case "$HTTP_CODE" in
  200) : ;;
  401|403)
    echo "local-delegate: server rejected the credentials (HTTP $HTTP_CODE) — check LOCAL_DELEGATE_API_KEY / the local_api_key option." >&2
    [ -s "$RESPF" ] && head -c 400 "$RESPF" >&2
    signal AUTH_REQUIRED "local server returned $HTTP_CODE (bad API key?)"; exit 11 ;;
  429)
    signal QUOTA_EXHAUSTED "local server returned 429 (rate limit / queue full — retry, or lower parallelism)"; exit 10 ;;
  404|400)
    case "$BODY_LC" in
      *model*not\ found*|*not\ found*model*|*model*does\ not\ exist*|*no\ such\ model*)
        echo "local-delegate: model '$MODEL' not found on $BASE — list what the server has: curl -s $BASE/models | python3 -m json.tool (or: ollama list)" >&2
        signal MODEL_UNAVAILABLE "model not on the local server (fix --model / local_tier_* options, or pull it: ollama pull $MODEL)"; exit 14 ;;
    esac
    echo "local-delegate: server returned HTTP $HTTP_CODE from $BASE" >&2
    [ -s "$RESPF" ] && head -c 400 "$RESPF" >&2
    echo "local-delegate:   (a 404 with no model mention usually means a wrong --host base URL — it should be the /v1 root)" >&2
    signal LOCAL_FAILED "local server HTTP $HTTP_CODE"; exit 2 ;;
  000)
    signal LOCAL_FAILED "no HTTP response from $BASE"; exit 2 ;;
  *)
    echo "local-delegate: server returned HTTP $HTTP_CODE" >&2
    [ -s "$RESPF" ] && head -c 400 "$RESPF" >&2
    signal LOCAL_FAILED "local server HTTP $HTTP_CODE"; exit 2 ;;
esac

# --- unwrap the response: content to stdout, one-line usage meta to stderr ------------
OUT="$(LD_RESP="$RESPF" python3 - <<'PY' 2>/dev/null || true
import json, os
try:
    d = json.load(open(os.environ["LD_RESP"], encoding="utf-8"))
except Exception:
    raise SystemExit(1)
msg = ((d.get("choices") or [{}])[0]).get("message") or {}
print(msg.get("content") or "")
PY
)"
META="$(LD_RESP="$RESPF" python3 - <<'PY' 2>/dev/null || true
import json, os
try:
    d = json.load(open(os.environ["LD_RESP"], encoding="utf-8"))
except Exception:
    raise SystemExit(1)
u = d.get("usage") or {}
def n(k):
    v = u.get(k)
    return v if isinstance(v, int) else 0
print(json.dumps({"input": n("prompt_tokens"), "output": n("completion_tokens"),
                  "total": n("total_tokens")}, separators=(",", ":")))
PY
)"
if [ -n "$META" ]; then
  printf 'LOCAL_USAGE {"backend":"local","model":"%s",%s}\n' "$MODEL" \
    "$(printf '%s' "$META" | sed 's/^{//; s/}$//')" >&2
fi

if [ -z "${OUT//[$' \t\n\r']/}" ]; then
  # an empty content with HTTP 200: some servers put the error in the body anyway
  grep -qi '"error"' "$RESPF" 2>/dev/null && head -c 400 "$RESPF" >&2
  echo "local-delegate: local model returned empty output (model='$MODEL')" >&2
  exit 3
fi

# --- output: file (with fence unwrap) or stdout --------------------------------------
if [ -n "$OUT_FILE" ]; then
  OUT_FINAL="$OUT"
  if [ "$RAW" -ne 1 ]; then
    OUT_FINAL="$(printf '%s' "$OUT" | LD_STRIP=1 python3 -c '
import re, sys
s = sys.stdin.read()
m = re.match(r"^\s*```[A-Za-z0-9_+-]*\s*\n(.*?)\n```\s*$", s, re.S)
sys.stdout.write(m.group(1) if m else s)
')"
  fi
  [ -d "$(dirname "$OUT_FILE")" ] || die "--out: directory does not exist: $(dirname "$OUT_FILE")"
  printf '%s\n' "$OUT_FINAL" >"$OUT_FILE"
  echo "local-delegate: wrote ${#OUT_FINAL} chars to $OUT_FILE (generated by the local model, written by the wrapper — nothing executed). VERIFY it: the caller owns correctness." >&2
else
  # Digest-size guard, same policy as agy-delegate (digest_warn_chars).
  WARN_CHARS="${CLAUDE_PLUGIN_OPTION_DIGEST_WARN_CHARS:-8000}"
  case "$WARN_CHARS" in (*[!0-9]*|'') WARN_CHARS=8000 ;; esac
  if [ "$WARN_CHARS" -gt 0 ] && [ "${#OUT}" -gt "$WARN_CHARS" ]; then
    echo "local-delegate: note: output is ${#OUT} chars (> ${WARN_CHARS}) — that looks like a raw dump, not a digest. Don't ingest this into the conductor's context: re-run with --digest, or --out <file> and read selectively." >&2
  fi
  printf '%s\n' "$OUT"
fi
