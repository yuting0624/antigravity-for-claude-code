#!/usr/bin/env bash
#
# agy-cost-compare.sh — run ONE task on agy (Gemini), then show what that same
# token volume would cost on Claude vs on Gemini Flash. A demo aid for the
# "let the cheap model do the bulk tokens" hypothesis.
#
# HONEST SCOPE / CAVEATS:
#   * agy v1.0.x has no token usage API in --print mode, so token counts here are
#     ESTIMATED from character count (chars / CHARS_PER_TOKEN). They are ballpark,
#     not billing-accurate.
#   * This prices the SAME measured volume at both price decks to visualize the
#     per-token price gap. The REAL saving in practice is larger, because Claude
#     as an orchestrator processes far fewer tokens than Claude doing everything.
#   * Prices below are PLACEHOLDERS. Override with the real Vertex rates for your
#     project before quoting numbers to anyone. Per 1M tokens, in USD.
#
# Usage:
#   agy-cost-compare.sh [-t flash|flash-lo|pro] "the task prompt"
#
# Env overrides (USD per 1M tokens):
#   CLAUDE_IN_PER_M  CLAUDE_OUT_PER_M     (default: 5 / 25   -- VERIFY!)
#   GEMINI_IN_PER_M  GEMINI_OUT_PER_M     (default: 0.30 / 2.50 -- VERIFY!)
#   CHARS_PER_TOKEN                       (default: 4)
#
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TIER="flash"

case "${1:-}" in -t|--tier) TIER="${2:-flash}"; shift 2 ;; esac
PROMPT="${*:-}"
[ -n "$PROMPT" ] || { echo "usage: agy-cost-compare.sh [-t tier] \"task\"" >&2; exit 1; }

CLAUDE_IN_PER_M="${CLAUDE_IN_PER_M:-5}"
CLAUDE_OUT_PER_M="${CLAUDE_OUT_PER_M:-25}"
GEMINI_IN_PER_M="${GEMINI_IN_PER_M:-0.30}"
GEMINI_OUT_PER_M="${GEMINI_OUT_PER_M:-2.50}"
CPT="${CHARS_PER_TOKEN:-4}"

echo ">> Delegating to agy (tier=$TIER) ..." >&2
START=$(date +%s 2>/dev/null || echo 0)
OUT="$("$HERE/agy-delegate.sh" --tier "$TIER" "$PROMPT")"
END=$(date +%s 2>/dev/null || echo 0)
ELAPSED=$(( END - START ))

IN_CHARS=${#PROMPT}
OUT_CHARS=${#OUT}

awk -v ic="$IN_CHARS" -v oc="$OUT_CHARS" -v cpt="$CPT" \
    -v cin="$CLAUDE_IN_PER_M" -v cout="$CLAUDE_OUT_PER_M" \
    -v gin="$GEMINI_IN_PER_M" -v gout="$GEMINI_OUT_PER_M" \
    -v el="$ELAPSED" 'BEGIN {
  it = ic / cpt; ot = oc / cpt;
  cc = it*cin/1e6 + ot*cout/1e6;
  gc = it*gin/1e6 + ot*gout/1e6;
  save = cc - gc;
  ratio = (gc > 0) ? cc / gc : 0;
  printf "\n--- estimated (chars/%d), NOT billing-accurate ---\n", cpt;
  printf "input  ~%d tokens (%d chars)\n", it, ic;
  printf "output ~%d tokens (%d chars)\n", ot, oc;
  printf "elapsed: %ds\n\n", el;
  printf "%-14s %12s %12s\n", "deck", "in $/1M", "out $/1M";
  printf "%-14s %12.2f %12.2f\n", "Claude", cin, cout;
  printf "%-14s %12.2f %12.2f\n\n", "Gemini Flash", gin, gout;
  printf "if priced as Claude: $%.6f\n", cc;
  printf "actual on Gemini   : $%.6f\n", gc;
  printf "saved on this task : $%.6f  (%.1fx cheaper)\n", save, ratio;
  printf "NOTE: real saving is larger — orchestrator Claude handles far fewer tokens.\n";
}'

echo ""
echo "----- agy output -----"
printf '%s\n' "$OUT"
