#!/usr/bin/env bash
#
# agy-cost-compare.sh — run ONE task on agy (Gemini), then show what that same
# token volume would cost on Claude vs on the resolved Gemini model. A demo aid
# for the "let the cheap/fast executor do the bulk tokens" hypothesis.
#
# HONEST SCOPE / CAVEATS:
#   * On agy >= 1.1.8 (JSON mode), token counts come directly from AGY_USAGE
#     (input, output including thinking, and additive cache_read). On older
#     plain-text runs without AGY_USAGE, counts fall back to chars / CHARS_PER_TOKEN.
#   * This prices the SAME measured volume at both price decks to visualize the
#     per-token price gap. The REAL saving in practice is larger, because Claude
#     as an orchestrator processes far fewer tokens than Claude doing everything.
#   * Prices in prices.json are global Vertex / Gemini API list rates. Override
#     with the real rates for your project before quoting numbers. Per 1M tokens, USD.
#
# Usage:
#   agy-cost-compare.sh [-t flash|flash-lo|lite|pro|neon|carbon|argon|flash-38] [-m model] [-e effort] [--yolo] "the task prompt"
#
# Env overrides (USD per 1M tokens):
#   CLAUDE_IN_PER_M  CLAUDE_OUT_PER_M     (default: prices.json claude_opus,
#                                          today 4 / 20 -- VERIFY!)
#   GEMINI_IN_PER_M  GEMINI_OUT_PER_M     (default: prices.json gemini_flash,
#                                          today 1.50 / 7.50 -- VERIFY against
#                                          your own Vertex rates)
#   AGY_PRICING_DATE                      (optional YYYY-MM-DD UTC override for
#                                          effective_from rate transitions)
#   CHARS_PER_TOKEN                       (default: 4, plain-text fallback only)
#
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/plugin-options.sh
. "$HERE/lib/plugin-options.sh"
load_plugin_options

TIER="flash"
MODEL=""
EFFORT=""
YOLO=""
while [ $# -gt 0 ]; do
  case "$1" in
    -t|--tier)   TIER="${2:-flash}"; shift 2 ;;
    -m|--model)  MODEL="${2:-}"; shift 2 ;;
    -e|--effort) EFFORT="${2:-}"; shift 2 ;;
    --yolo)      YOLO="--yolo"; shift ;;   # needed if the task uses tools (web/Vertex search)
    --)          shift; break ;;
    -*)          echo "unknown option: $1" >&2; exit 1 ;;
    *)           break ;;
  esac
done
PROMPT="${*:-}"
[ -n "$PROMPT" ] || { echo "usage: agy-cost-compare.sh [-t tier] [-m model] [-e effort] [--yolo] \"task\"" >&2; exit 1; }

# Configured tier models (PRO_MODEL pinned against agy-delegate.sh and doctor.sh in run-tests.sh);
# overridden below if agy-delegate reports a different model in AGY_USAGE or a runtime fallback.
FLASH_MODEL="${CLAUDE_PLUGIN_OPTION_TIER_FLASH:-Gemini 4 Hydrogen (High)}"
FLASH_LO_MODEL="${CLAUDE_PLUGIN_OPTION_TIER_FLASH_LO:-Gemini 4 Hydrogen (Low)}"
PRO_MODEL="${CLAUDE_PLUGIN_OPTION_TIER_PRO:-Gemini 4 Neon (High)}"
case "$TIER" in
  flash)         RESOLVED_MODEL="$FLASH_MODEL" ;;
  flash-lo|lite) RESOLVED_MODEL="$FLASH_LO_MODEL" ;;
  pro)           RESOLVED_MODEL="$PRO_MODEL" ;;
  neon)          RESOLVED_MODEL="${CLAUDE_PLUGIN_OPTION_TIER_NEON:-Gemini 4 Neon (High)}" ;;
  carbon)        RESOLVED_MODEL="${CLAUDE_PLUGIN_OPTION_TIER_CARBON:-Gemini 4 Carbon (High)}" ;;
  argon)         RESOLVED_MODEL="${CLAUDE_PLUGIN_OPTION_TIER_ARGON:-Gemini 4 Argon (High)}" ;;
  flash-38)      RESOLVED_MODEL="${CLAUDE_PLUGIN_OPTION_TIER_FLASH_38:-Gemini 3.8 Flash (High)}" ;;
  *)             RESOLVED_MODEL="$FLASH_MODEL" ;;
esac
[ -n "$MODEL" ] && RESOLVED_MODEL="$MODEL"

DEL_ERR="$(mktemp "${TMPDIR:-/tmp}/agy-cc-err.XXXXXX")"
trap 'rm -f "$DEL_ERR" 2>/dev/null' EXIT

DEL_ARGS=(--tier "$TIER")
[ -n "$MODEL" ]  && DEL_ARGS+=(--model "$MODEL")
[ -n "$EFFORT" ] && DEL_ARGS+=(--effort "$EFFORT")
[ -n "$YOLO" ]   && DEL_ARGS+=("$YOLO")

echo ">> Delegating to agy (tier=$TIER${MODEL:+ model=$MODEL}${EFFORT:+ effort=$EFFORT}) ..." >&2
START=$(date +%s 2>/dev/null || echo 0)
# Stream the delegate's stderr live AND keep a copy for the price lookup below. A
# `2> >(tee ...)` process substitution would do both, but a bare `wait` does not wait
# for it on bash < 4.4 (macOS ships 3.2), so python could read $DEL_ERR before tee had
# flushed the AGY_USAGE line and silently price a fallback run at the wrong rate. A
# named pipe gives tee a PID we can wait on explicitly; if mkfifo is unavailable, fall
# back to buffering stderr in the file and replaying it afterwards.
set +e
FIFO="$(mktemp -u "${TMPDIR:-/tmp}/agy-cc-fifo.XXXXXX")"
if mkfifo "$FIFO" 2>/dev/null; then
  trap 'rm -f "$DEL_ERR" "$FIFO" 2>/dev/null' EXIT
  tee "$DEL_ERR" <"$FIFO" >&2 &
  TEE_PID=$!
  OUT="$("$HERE/agy-delegate.sh" "${DEL_ARGS[@]}" "$PROMPT" 2>"$FIFO")"
  RC=$?
  wait "$TEE_PID" 2>/dev/null
  rm -f "$FIFO"
else
  OUT="$("$HERE/agy-delegate.sh" "${DEL_ARGS[@]}" "$PROMPT" 2>"$DEL_ERR")"
  RC=$?
  [ -s "$DEL_ERR" ] && cat "$DEL_ERR" >&2
fi
set -e
[ "$RC" -eq 0 ] || exit "$RC"
END=$(date +%s 2>/dev/null || echo 0)
ELAPSED=$(( END - START ))

# Default prices from prices.json (env vars still override); Gemini rate resolved from
# the model that actually ran (AGY_USAGE.model or fallback notice), across all tiers.
PRICES="$HERE/../prices.json"
if [ -f "$PRICES" ] && command -v python3 >/dev/null 2>&1; then
  eval "$(python3 - "$PRICES" "$TIER" "$RESOLVED_MODEL" "$DEL_ERR" 2>/dev/null <<'PY'
from datetime import datetime, timezone
import json, os, re, shlex, sys

def resolve_effective_deck(base_key, d, pricing_date):
    best = d.get(base_key)
    best_date = ""
    prefix = base_key + "_post_"
    for k, v in d.items():
        if k.startswith(prefix) and isinstance(v, dict):
            eff = str(v.get("effective_from") or "").strip()
            if eff and eff <= pricing_date and eff >= best_date:
                best = v
                best_date = eff
    return best

def deck_for_model(pm, tier, d, pricing_date):
    s = (pm or "").lower()
    for check, key in (
        ("neon" in s, "gemini_neon"),
        ("carbon" in s, "gemini_carbon"),
        ("argon" in s, "gemini_argon"),
        ("hydrogen" in s, "gemini_hydrogen"),
        ("3.5" in s and "lite" in s, "gemini_flash_lite_35"),
        ("3.1" in s and "lite" in s, "gemini_flash_lite_31"),
        ("3.8" in s, "gemini_flash_38"),
        ("3.7" in s, "gemini_flash_37"),
        ("3.6" in s, "gemini_flash_36"),
        ("3.5" in s and "flash" in s, "gemini_flash_35"),
        ("pro" in s, "gemini_pro"),
        ("sonnet" in s, "claude_sonnet"),
        ("opus" in s, "claude_opus"),
    ):
        if check and key in d:
            return resolve_effective_deck(key, d, pricing_date)
    tier_map = {
        "pro": "gemini_neon",
        "neon": "gemini_neon",
        "carbon": "gemini_carbon",
        "argon": "gemini_argon",
        "flash-38": "gemini_flash_38",
    }
    tk = tier_map.get(tier, "gemini_flash")
    return resolve_effective_deck(tk, d, pricing_date) or d["gemini_flash"]

try:
    d = json.load(open(sys.argv[1]))
    t, pm, errf = sys.argv[2], sys.argv[3], sys.argv[4]
    raw_pdate = (os.environ.get("AGY_PRICING_DATE") or "").strip()
    pricing_date = (raw_pdate if re.match(r"^\d{4}-\d{2}-\d{2}$", raw_pdate)
                    else datetime.now(timezone.utc).strftime("%Y-%m-%d"))
    u_in = u_out = u_cr = 0
    if os.path.isfile(errf):
        for line in open(errf, encoding="utf-8", errors="replace").read().splitlines():
            if line.startswith("AGY_USAGE "):
                try:
                    u = json.loads(line[len("AGY_USAGE "):])
                    if isinstance(u, dict):
                        if u.get("model"):
                            pm = str(u["model"])
                        us = u.get("usage")
                        if isinstance(us, dict):
                            u_in = int(us.get("input") or 0)
                            u_out = int(us.get("output") or 0)
                            u_cr = int(us.get("cache_read") or 0)
                except Exception:
                    pass
            m = re.search(r"\bfell back to ([^(]+)", line)
            if m:
                pm = m.group(1).strip()
    g = deck_for_model(pm, t, d, pricing_date)
    c = d["claude_opus"]
    ccrm = float(d.get("cache_read_mult", 0.05))
    gcrd = float(g.get("cached_in", 0.0))
    has_u = 1 if (u_in + u_out + u_cr) > 0 else 0
    lbl = (" ".join((pm or "Gemini").split()))[:24]
    print(
        f'_CIN={c["in"]} _COUT={c["out"]} _CCRM={ccrm} '
        f'_GIN={g["in"]} _GOUT={g["out"]} _GCRD={gcrd} '
        f'_HAS_USAGE={has_u} _UIN={u_in} _UOUT={u_out} _UCR={u_cr} '
        f'_GLABEL={shlex.quote(lbl)}'
    )
except Exception:
    pass
PY
)"
fi
# Last-resort fallbacks, used only when prices.json or python3 is unavailable. Keep them
# in step with prices.json — a stale hardcoded rate here quotes a wrong number in exactly
# the situation where nobody can see where it came from.
CLAUDE_IN_PER_M="${CLAUDE_IN_PER_M:-${_CIN:-4}}"
CLAUDE_OUT_PER_M="${CLAUDE_OUT_PER_M:-${_COUT:-20}}"
GEMINI_IN_PER_M="${GEMINI_IN_PER_M:-${_GIN:-1.5}}"
GEMINI_OUT_PER_M="${GEMINI_OUT_PER_M:-${_GOUT:-7.5}}"
CLAUDE_CRM="${_CCRM:-0.05}"
GEMINI_CACHED_IN="${_GCRD:-0.075}"
HAS_USAGE="${_HAS_USAGE:-0}"
U_IN="${_UIN:-0}"
U_OUT="${_UOUT:-0}"
U_CR="${_UCR:-0}"
GLABEL="${_GLABEL:-Gemini}"
CPT="${CHARS_PER_TOKEN:-4}"
case "$CPT" in ''|*[!0-9]*) CPT=4 ;; esac   # must be a positive integer (avoid awk div-by-zero)
[ "$CPT" -gt 0 ] || CPT=4

IN_CHARS=${#PROMPT}
OUT_CHARS=${#OUT}

awk -v ic="$IN_CHARS" -v oc="$OUT_CHARS" -v cpt="$CPT" \
    -v has_u="$HAS_USAGE" -v uin="$U_IN" -v uout="$U_OUT" -v ucr="$U_CR" \
    -v cin="$CLAUDE_IN_PER_M" -v cout="$CLAUDE_OUT_PER_M" -v ccrm="$CLAUDE_CRM" \
    -v gin="$GEMINI_IN_PER_M" -v gout="$GEMINI_OUT_PER_M" -v gcrd="$GEMINI_CACHED_IN" \
    -v glbl="$GLABEL" -v el="$ELAPSED" 'BEGIN {
  if (has_u == 1) {
    # AGY_USAGE contract: output already includes thinking; cache_read is a separate
    # additive counter (not a subset of input).
    it = uin; ot = uout; crt = ucr;
    cc = (it*cin + ot*cout + crt*cin*ccrm) / 1e6;
    gc = (it*gin + ot*gout + crt*gcrd) / 1e6;
    printf "\n--- measured from AGY_USAGE (lower bound: cache storage omitted) ---\n";
    printf "input      %d tokens\n", it;
    printf "output     %d tokens (includes thinking)\n", ot;
    if (crt > 0) printf "cache_read %d tokens (additive)\n", crt;
  } else {
    it = ic / cpt; ot = oc / cpt;
    cc = it*cin/1e6 + ot*cout/1e6;
    gc = it*gin/1e6 + ot*gout/1e6;
    printf "\n--- estimated (chars/%d), NOT billing-accurate ---\n", cpt;
    printf "input  ~%d tokens (%d chars)\n", it, ic;
    printf "output ~%d tokens (%d chars)\n", ot, oc;
  }
  save = cc - gc;
  ratio = (gc > 0) ? cc / gc : 0;
  printf "elapsed: %ds\n\n", el;
  printf "%-24s %12s %12s\n", "deck", "in $/1M", "out $/1M";
  printf "%-24s %12.2f %12.2f\n", "Claude", cin, cout;
  printf "%-24s %12.2f %12.2f\n\n", glbl, gin, gout;
  printf "if priced as Claude: $%.6f\n", cc;
  printf "actual on Gemini   : $%.6f\n", gc;
  printf "saved on this task : $%.6f  (%.1fx cheaper)\n", save, ratio;
  printf "NOTE: real saving is larger — orchestrator Claude handles far fewer tokens.\n";
}'

echo ""
echo "----- agy output -----"
printf '%s\n' "$OUT"
