#!/usr/bin/env bash
#
# cloud-debug.sh — fetch a GCP resource's recent ERROR logs and hand them to
# Antigravity (`agy` / Gemini) for a compact, structured digest.
# Part of the "Antigravity for Claude Code" plugin.
#
# This is the Executor half of the /antigravity:cloud-run-debug command:
# Claude (the Conductor) reasons about root cause + the fix; the bulk, cheap
# work — pulling potentially hundreds of log lines and clustering them into a
# digest — is offloaded here to agy so Claude's context stays lean.
#
# It is deliberately READ-ONLY: it reads logs and produces a digest. It never
# applies fixes and never writes to your project (the `--apply` flow lives in
# the command, driven by Claude on a branch). The default resource type is
# Cloud Run (cloud_run_revision); `--resource-type` is parameterized so the
# same engine can back a future gke-debug / functions-debug without a rewrite.
#
# The agy digest step reuses scripts/agy-delegate.sh (the plugin's one
# delegation wrapper) — no new delegation logic here.
#
# Usage:
#   cloud-debug.sh --service <name> [options]
#
# Options:
#   -s, --service <name>           Cloud Run service name (required)
#   -r, --region  <r>             Location/region (omit to query all regions)
#       --since <dur>             Log freshness window, e.g. 1h, 30m, 2d (default: 1h)
#       --limit <n>              Max log entries to fetch (default: 200)
#       --severity <SEV>         Minimum severity (default: ERROR)
#       --resource-type <type>    GCP resource.type (default: cloud_run_revision)
#   -p, --project <id>           GCP project (default: gcloud config's project)
#   -t, --tier <flash|flash-lo|pro>  agy tier for the digest (default: flash)
#       --print-command          Print the resolved gcloud + agy commands and exit (dry run)
#   -h, --help                   Show this help
#
# Exit codes:
#   0  ok (digest printed, or query succeeded with no matching logs)
#   1  usage error
#   2  gcloud read failed (generic)
#   3  permission denied — needs roles/logging.viewer (guidance printed)
#   4  gcloud not on PATH
#   5  agy digest step failed (agy-delegate stderr is surfaced)
#
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
DELEGATE="$HERE/agy-delegate.sh"

SERVICE=""
REGION=""
SINCE="1h"
LIMIT="200"
SEVERITY="ERROR"
RESOURCE_TYPE="cloud_run_revision"
PROJECT=""
TIER="flash"
PRINT_CMD=0

die() { echo "cloud-debug: $*" >&2; exit 1; }
# $1 = remaining argc ($#). Fail clearly when an option is missing its value
# (mirrors agy-delegate.sh so `shift 2` never aborts cryptically under set -e).
need() { [ "$1" -ge 2 ] || die "option '$2' needs a value"; }

# Print the header comment between "# Usage:" and "# Exit codes:" (anchored to
# content, not line numbers — same trick as agy-delegate.sh).
usage() { sed -n '/^# Usage:/,/^# Exit codes:/p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

while [ $# -gt 0 ]; do
  case "$1" in
    -s|--service)       need "$#" "$1"; SERVICE="$2"; shift 2 ;;
    -r|--region)        need "$#" "$1"; REGION="$2"; shift 2 ;;
    --since)            need "$#" "$1"; SINCE="$2"; shift 2 ;;
    --limit)            need "$#" "$1"; LIMIT="$2"; shift 2 ;;
    --severity)         need "$#" "$1"; SEVERITY="$2"; shift 2 ;;
    --resource-type)    need "$#" "$1"; RESOURCE_TYPE="$2"; shift 2 ;;
    -p|--project)       need "$#" "$1"; PROJECT="$2"; shift 2 ;;
    -t|--tier)          need "$#" "$1"; TIER="$2"; shift 2 ;;
    --print-command)    PRINT_CMD=1; shift ;;
    -h|--help)          usage ;;
    --)                 shift; break ;;
    -*)                 die "unknown option '$1'" ;;
    *)                  die "unexpected argument '$1' (this command takes only options)" ;;
  esac
done

[ -n "$SERVICE" ] || die "no --service given (the Cloud Run service to diagnose)"
case "$LIMIT" in (*[!0-9]*|'') die "--limit must be a positive integer (got '$LIMIT')" ;; esac

# gcloud is required for the real run; --print-command is a dry run (introspection)
# and only resolves the project from gcloud config when it's available.
if [ "$PRINT_CMD" -ne 1 ] && ! command -v gcloud >/dev/null 2>&1; then
  echo "cloud-debug: 'gcloud' not found on PATH — install the Google Cloud CLI first:" >&2
  echo "cloud-debug:   https://cloud.google.com/sdk/docs/install" >&2
  exit 4
fi

# Resolve the project: explicit --project wins, else gcloud's configured project.
if [ -z "$PROJECT" ] && command -v gcloud >/dev/null 2>&1; then
  PROJECT="$(gcloud config get-value project 2>/dev/null || true)"
  # gcloud emits "(unset)" when no project is configured — treat that as empty.
  [ "$PROJECT" = "(unset)" ] && PROJECT=""
fi
if [ -z "$PROJECT" ]; then
  if [ "$PRINT_CMD" -eq 1 ]; then
    PROJECT="<project>"   # placeholder so the dry run still renders a full command
  else
    die "no GCP project (pass --project <id>, or run 'gcloud config set project <id>')"
  fi
fi

# --- build the Logging filter ---
# Default labels are Cloud Run's (service_name / location). Other resource types
# may key these differently; that's the seam a future gke/functions command
# would adjust. severity>=ERROR (overridable) keeps the volume — and cost — bounded.
FILTER="resource.type=\"$RESOURCE_TYPE\""
FILTER="$FILTER AND resource.labels.service_name=\"$SERVICE\""
[ -n "$REGION" ] && FILTER="$FILTER AND resource.labels.location=\"$REGION\""
FILTER="$FILTER AND severity>=$SEVERITY"

GCLOUD_ARGS=(logging read "$FILTER"
  "--freshness=$SINCE" "--limit=$LIMIT" --format=json "--project=$PROJECT")

# --- the digest instruction handed to agy alongside the logs ---
# Worded as a summary task (no implement/scaffold/migrate words) so agy-delegate's
# write-task heuristic doesn't fire — this stage only reads and reports.
read -r -d '' INSTRUCTION <<'PROMPT' || true
You are a log-analysis assistant. Below is a JSON array of GCP log entries at
the requested severity or higher. Produce a COMPACT, structured digest — do NOT
echo the raw logs back. Use exactly these sections:

## ERROR CLUSTERS
Group entries by error signature (normalize variable bits like ids, hashes,
timestamps). For each cluster give: a one-line label, the count, and first/last
seen time.

## REPRESENTATIVE STACK TRACE(S)
For the top 1-3 clusters, the single most representative stack trace or error
message, trimmed to the relevant frames.

## TIME DISTRIBUTION
One or two lines: were the errors bursty or steady? any spike, and when?

## LIKELY ROOT-CAUSE CANDIDATES
2-5 ranked hypotheses, each one line, naming which cluster supports it
(e.g. missing env var, unhandled exception, bad config, dependency/timeout).

Be concise. Output ONLY the digest.

--- LOG ENTRIES (JSON) ---
PROMPT

# --- dry run: show the resolved pipeline and exit (no gcloud / agy call) ---
if [ "$PRINT_CMD" -eq 1 ]; then
  { printf 'gcloud'; printf ' %q' "${GCLOUD_ARGS[@]}"; printf '\n'; }
  printf '  | %s --tier %q -\n' "$DELEGATE" "$TIER"
  exit 0
fi

# --- fetch logs ---
ERR="$(mktemp "${TMPDIR:-/tmp}/cloud-debug.XXXXXX")"
trap 'rm -f "$ERR"' EXIT

set +e
LOGS="$(gcloud "${GCLOUD_ARGS[@]}" 2>"$ERR")"
RC=$?
set -e

if [ "$RC" -ne 0 ]; then
  echo "cloud-debug: gcloud logging read failed (exit $RC)" >&2
  [ -s "$ERR" ] && cat "$ERR" >&2
  # Classify a permissions failure so we can point at the exact role to grant.
  blob="$(cat "$ERR" 2>/dev/null)"
  shopt -s nocasematch
  case "$blob" in
    *permission_denied*|*"does not have permission"*|*"permission to access"*|*"logging.logEntries.list"*|*"403"*)
      shopt -u nocasematch
      echo "cloud-debug: this looks like a permissions problem — your account needs Logs Viewer." >&2
      echo "cloud-debug:   grant roles/logging.viewer on project '$PROJECT', e.g.:" >&2
      echo "cloud-debug:   gcloud projects add-iam-policy-binding $PROJECT \\" >&2
      echo "cloud-debug:     --member='user:YOUR_EMAIL' --role='roles/logging.viewer'" >&2
      exit 3 ;;
  esac
  shopt -u nocasematch
  exit 2
fi

# No matching logs is a valid diagnostic result, not an error.
case "${LOGS//[[:space:]]/}" in
  ''|'[]')
    echo "cloud-debug: no logs at severity>=$SEVERITY for service '$SERVICE'${REGION:+ in $REGION} within --since $SINCE."
    echo "cloud-debug: widen the window (--since), lower --severity, or confirm the service name/region."
    exit 0 ;;
esac

# --- delegate the digest to agy (cheap tier; lean output back to Claude) ---
set +e
DIGEST="$(printf '%s\n%s\n' "$INSTRUCTION" "$LOGS" | "$DELEGATE" --tier "$TIER" - 2>"$ERR")"
RC=$?
set -e

if [ "$RC" -ne 0 ]; then
  echo "cloud-debug: agy digest step failed (agy-delegate exit $RC)" >&2
  [ -s "$ERR" ] && cat "$ERR" >&2
  exit 5
fi

printf '%s\n' "$DIGEST"
