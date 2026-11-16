#!/usr/bin/env bash
#
# agy-job.sh — background-job layer over agy-delegate.sh, à la `codex --background`.
# For INTERACTIVE Claude Code sessions: fire a long delegation, keep working, then
# poll :status / fetch :result. (Headless `claude -p` is one-shot — use the wrapper
# synchronously there instead; there is no later turn to collect the result.)
#
# Usage:
#   agy-job.sh start  [agy-delegate options] "task"   # -> prints a JOB_ID, returns now
#   agy-job.sh list                                    # jobs started from this dir
#   agy-job.sh status <id>                             # running | done(rc) | failed | cancelled
#   agy-job.sh result <id>                             # print stdout (+rc) when finished
#   agy-job.sh cancel <id>                             # terminate a running job (and its tree)
#
# Jobs live under ${ANTIGRAVITY_JOBS:-~/.antigravity-jobs}/<id>/ (out, err, rc, cancelled, meta).
#
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
DELEGATE="${AGY_DELEGATE:-$HERE/agy-delegate.sh}"
REG="${ANTIGRAVITY_JOBS:-$HOME/.antigravity-jobs}"

die() { echo "agy-job: $*" >&2; exit 1; }

# resolve a (possibly abbreviated) id to a job dir.
# Callers run this inside `$(...)`, so `die` only leaves the SUBSHELL: the parent kept
# going with jd="" and job_state "" rendered `state=failed` for an id that never existed
# (#96). Every call site therefore reads `jd="$(jobdir ...)" || exit 1`.
jobdir() {
  [ -n "${1:-}" ] || die "need a job id"
  if [ -d "$REG/$1" ]; then echo "$REG/$1"; return; fi
  local hits; hits=$(ls -d "$REG/$1"* 2>/dev/null)
  [ -n "$hits" ] || die "no such job: $1"
  [ "$(printf '%s\n' "$hits" | grep -c .)" -eq 1 ] || die "ambiguous id '$1'"
  echo "$hits"
}

# True when $2 is alive AND matches the `ps -p ... -o lstart=` timestamp captured at job
# start (when available), preventing a recycled PID from keeping a crashed job "running"
# or making `cancel` signal an unrelated process tree. On Windows Git Bash / stubs where
# `ps -p -o lstart=` returns empty, falls back to `kill -0`.
pid_alive() {
  local jd="$1" p="${2:-}" want cur
  [ -n "$p" ] && kill -0 "$p" 2>/dev/null || return 1
  if [ -s "$jd/pid_start" ]; then
    want="$(cat "$jd/pid_start" 2>/dev/null || true)"
    cur="$(ps -p "$p" -o lstart= 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    if [ -n "$want" ] && [ -n "$cur" ] && [ "$want" != "$cur" ]; then
      return 1
    fi
  fi
  return 0
}

# Atomically claims `$jd/final` with payload $2 (`rc:<code>` or `cancelled`) by hard-linking
# a pre-populated temp file (`link(2)` leaves zero gap between lock acquisition and payload
# visibility, even under SIGKILL; falls back to POSIX `set -C` `O_CREAT|O_EXCL` if `ln` is
# unsupported on the filesystem).
claim_final() {
  local jd="$1" val="$2" tmp="$1/.claim.$$.$RANDOM" ok=0
  printf '%s\n' "$val" > "$tmp" 2>/dev/null || return 1
  if ln "$tmp" "$jd/final" 2>/dev/null; then
    ok=1
  elif [ ! -e "$jd/final" ] && ( set -C; printf '%s\n' "$val" > "$jd/final" ) 2>/dev/null; then
    ok=1
  fi
  rm -f "$tmp" 2>/dev/null || true
  [ "$ok" -eq 1 ]
}

# echoes running | done | failed | cancelled. (rc is read directly from the file by
# callers — a global set here would NOT survive the `$(job_state ...)` subshell.)
# Both normal completion (`start` / `agy-handoff --background`) and `cancel` claim
# `$jd/final` atomically via `claim_final`, so `rc` and `cancelled` are mutually exclusive
# with zero gap between claiming `.final` and recording which side won.
job_state() {
  local jd="$1" rc fv
  fv="$(cat "$jd/final" 2>/dev/null || true)"
  if [ -f "$jd/rc" ]; then
    rc="$(cat "$jd/rc")"
    if [ "$rc" = "0" ]; then echo "done"; else echo "failed"; fi
  elif case "$fv" in rc:*) true ;; *) false ;; esac; then
    rc="${fv#rc:}"
    if [ "$rc" = "0" ]; then echo "done"; else echo "failed"; fi
  elif [ "$fv" = "cancelled" ] || [ -f "$jd/cancelled" ]; then
    echo "cancelled"
  elif [ -f "$jd/pid" ] && pid_alive "$jd" "$(cat "$jd/pid" 2>/dev/null || true)"; then
    echo "running"
  else
    echo "failed"   # pid gone (or recycled), no rc recorded = crashed/killed
  fi
}

# Emits "<pid> <ppid> <winpid>" rows across active processes (winpid is "-" off Windows).
# On Git Bash / MSYS2 / Cygwin (`ps -e`), rows may carry a leading 1-letter status flag
# (`S`, `I`, `R`, `O`) in column 1 while the header row starts directly with `PID`:
# compute PPID/WINPID offsets relative to PID from NR==1 (default +1, +3), then locate
# each row's numeric PID at $1 or $2 (#117).
proc_table() {
  case "$(uname -s 2>/dev/null)" in
    MINGW*|MSYS*|CYGWIN*)
      ps -e 2>/dev/null | awk '
        BEGIN { d_ppid = 1; d_win = 3; has_win = 1 }
        NR == 1 && ($1 == "PID" || $2 == "PID") {
          h_pid = 0; h_ppid = 0; h_win = 0
          for (k = 1; k <= NF; k++) {
            if ($k == "PID")    h_pid = k
            if ($k == "PPID")   h_ppid = k
            if ($k == "WINPID") h_win = k
          }
          if (h_pid > 0 && h_ppid > 0) d_ppid = h_ppid - h_pid
          if (h_pid > 0 && h_win > 0)  { d_win = h_win - h_pid; has_win = 1 }
          else                         { has_win = 0 }
          next
        }
        {
          i = ($1 ~ /^[0-9]+$/) ? 1 : 2
          pid = $i; ppid = $(i + d_ppid)
          win = has_win ? $(i + d_win) : "-"
          if (pid ~ /^[0-9]+$/ && ppid ~ /^[0-9]+$/) {
            if (win !~ /^[0-9]+$/) win = "-"
            print pid, ppid, win
          }
        }' ;;
    *)
      ps -eo pid=,ppid= 2>/dev/null | awk '
        $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ { print $1, $2, "-" }' ;;
  esac
}

# Echoes "<pid> <winpid>" for the space-separated root PID(s) in $1 and all their
# descendants in top-down breadth-first order (root/parents first, deepest leaves last),
# excluding the current agy-job shell ($2) and its subshell/ps/awk pipeline.
# Keep $1 single-line space-separated: macOS BSD `/usr/bin/awk` rejects literal newlines
# inside `-v var=...` arguments.
job_tree() {
  proc_table | awk -v roots="$1" -v self="$2" '
    $1 == self || $2 == self { next }
    {
      if (!($1 in pp)) ord[++m] = $1
      pp[$1] = $2
      w[$1] = $3
    }
    END {
      nr = split(roots, rlist)
      n = 0
      for (r = 1; r <= nr; r++) {
        rt = rlist[r]
        if (rt != "" && rt != self && !(rt in seen)) {
          q[++n] = rt
          seen[rt] = 1
        }
      }
      for (head = 1; head <= n; head++) {
        cur = q[head]
        for (idx = 1; idx <= m; idx++) {
          p = ord[idx]
          if (!(p in seen) && pp[p] == cur) {
            q[++n] = p
            seen[p] = 1
          }
        }
      }
      for (k = 1; k <= n; k++) {
        p = q[k]
        print p, ((p in w) ? w[p] : "-")
      }
    }'
}

resume_tree() {
  local p
  while read -r p _; do
    [ -n "$p" ] && { kill -CONT "$p" 2>/dev/null || true; }
  done <<EOF
${1:-}
EOF
}

abort_cancel() {
  local jd="${1:-}" owned="${2:-0}" t="${3:-}"
  trap - INT TERM HUP
  [ -n "$t" ] && resume_tree "$t"
  if [ "$owned" = "1" ] && [ -n "$jd" ]; then
    rm -f "$jd/cancelled" "$jd/final" 2>/dev/null || true
  fi
  exit 130
}

# Human label for a delegate / hand-off exit code (mirrors agy-delegate.sh / agy-handoff.sh codes).
rc_label() {
  case "$1" in
    0)  echo 'ok' ;;
    2)  echo 'agy failed' ;;
    3)  echo 'empty output' ;;
    4)  echo 'VERIFY failed — tests still red after the allowed fix-ups (agy-handoff)' ;;
    6)  echo 'TESTS modified — a protected --tests file was edited by the executor (agy-handoff)' ;;
    10) echo 'QUOTA — retry later with --continue' ;;
    11) echo 'AUTH required — run `agy` once interactively' ;;
    12) echo 'TIMEOUT — raise --timeout or narrow scope (agy 1.1.28+: the PARTIAL reply is in the output, rc 0 on 1.1.28–1.4.x / rc 3 on 1.5.0+; --continue resumes the conversation)' ;;
    13) echo 'agy MISSING — install the Antigravity CLI' ;;
    14) echo 'MODEL unavailable — check `agy models` / tier remap' ;;
    # Both denial shapes: the soft deny (agy 1.1.3+, and again from 1.1.20) and 1.1.13's hard error.
    15) echo 'PERMISSION denied (soft on 1.1.3+, a hard error by 1.1.13, soft again from 1.1.20; named in denied_actions since 1.1.27; policy_blocked under --yolo on 1.5.2+) — add a permissions.allow rule, pass --yolo, or check admin policy' ;;
    *)  echo 'error' ;;
  esac
}

cmd="${1:-}"; shift || true
case "$cmd" in
  start)
    [ $# -ge 1 ] || die "start needs delegate args, e.g.  start --tier pro \"task\""
    [ -x "$DELEGATE" ] || die "delegate not executable: $DELEGATE"
    id="$(date +%Y%m%d-%H%M%S)-$$-${RANDOM}"
    jd="$REG/$id"; mkdir -p "$jd"
    { echo "id=$id"; echo "cwd=$PWD"; echo "started=$(date -u +%FT%TZ 2>/dev/null || date)";
      echo "task=$(printf '%s' "${!#}" | tr '\n' ' ' | cut -c1-200)"; } > "$jd/meta"
    ( nohup "$DELEGATE" "$@" >"$jd/out" 2>"$jd/err"; rc=$?; if claim_final "$jd" "rc:$rc"; then printf '%s\n' "$rc" >"$jd/rc.tmp" && mv -f "$jd/rc.tmp" "$jd/rc"; fi ) >/dev/null 2>&1 &
    bg_pid=$!
    echo "$bg_pid" > "$jd/pid"
    pstart="$(ps -p "$bg_pid" -o lstart= 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [ -n "$pstart" ] && printf '%s\n' "$pstart" > "$jd/pid_start"
    disown 2>/dev/null || true
    echo "$id"
    ;;
  list)
    [ -d "$REG" ] || { echo "(no jobs)"; exit 0; }
    found=0
    for jd in "$REG"/*/; do
      [ -d "$jd" ] || continue
      cwd="$(sed -n 's/^cwd=//p' "$jd/meta" 2>/dev/null)"
      [ "${ALL:-0}" = "1" ] || [ "$cwd" = "$PWD" ] || continue
      found=1
      st="$(job_state "$jd")"
      printf '%-32s %-9s %s\n' "$(basename "$jd")" "$st" \
        "$(sed -n 's/^task=//p' "$jd/meta" 2>/dev/null)"
    done
    [ "$found" = "1" ] || echo "(no jobs for $PWD — set ALL=1 to see all)"
    ;;
  status)
    jd="$(jobdir "${1:-}")" || exit 1; st="$(job_state "$jd")"
    rc="$(cat "$jd/rc" 2>/dev/null || true)"
    if [ -z "$rc" ]; then
      fv="$(cat "$jd/final" 2>/dev/null || true)"
      case "$fv" in rc:*) rc="${fv#rc:}" ;; esac
    fi
    echo "job:    $(basename "$jd")"
    sed 's/^/  /' "$jd/meta" 2>/dev/null
    if [ "$st" != "cancelled" ] && [ -n "$rc" ]; then
      echo "  state=$st (rc=$rc: $(rc_label "$rc"))"
    else
      echo "  state=$st"
    fi
    sig="$(grep -m1 '^AGY_SIGNAL ' "$jd/err" 2>/dev/null || true)"
    if [ -n "$sig" ]; then echo "  signal=${sig#AGY_SIGNAL }"; fi
    ;;
  result)
    jd="$(jobdir "${1:-}")" || exit 1; st="$(job_state "$jd")"
    if [ "$st" = "running" ]; then echo "still running — try again later"; exit 2; fi
    [ -s "$jd/err" ] && { echo "----- stderr -----" >&2; cat "$jd/err" >&2; }
    cat "$jd/out" 2>/dev/null
    # `result` exits 2 only while still running and exits 0 whenever output is ready to
    # read (including failed jobs below, whose rc is reported on stderr / `status`).
    if [ "$st" = "cancelled" ]; then
      echo "[cancelled]" >&2
      exit 0
    fi
    rc="$(cat "$jd/rc" 2>/dev/null || true)"
    if [ -z "$rc" ]; then
      fv="$(cat "$jd/final" 2>/dev/null || true)"
      case "$fv" in rc:*) rc="${fv#rc:}" ;; esac
    fi
    echo "[exit rc=${rc:-?}${rc:+: $(rc_label "$rc")}]" >&2
    ;;
  cancel)
    jd="$(jobdir "${1:-}")" || exit 1
    fv="$(cat "$jd/final" 2>/dev/null || true)"
    case "$fv" in rc:*) echo "not running"; exit 0 ;; esac
    if [ -f "$jd/rc" ]; then echo "not running"; exit 0; fi
    pid="$(cat "$jd/pid" 2>/dev/null || true)"
    already_claimed=0
    if [ "$fv" = "cancelled" ] || [ -f "$jd/cancelled" ]; then
      # If an earlier cancel died via SIGKILL after claiming `final` while the job tree
      # is still alive (or SIGSTOPped), fall through to finish terminating it.
      if ! pid_alive "$jd" "$pid"; then echo "already cancelled"; exit 0; fi
      already_claimed=1
    fi
    if [ "$already_claimed" -eq 1 ] || pid_alive "$jd" "$pid"; then
      owns_final=0; tree=""
      if [ "$already_claimed" -eq 0 ]; then
        trap 'abort_cancel "$jd" "$owns_final" "${tree:-}"' INT TERM HUP
        if claim_final "$jd" "cancelled"; then
          owns_final=1
        else
          trap - INT TERM HUP
          fv="$(cat "$jd/final" 2>/dev/null || true)"
          if [ "$fv" = "cancelled" ] || [ -f "$jd/cancelled" ]; then
            if ! pid_alive "$jd" "$pid"; then echo "already cancelled"; exit 0; fi
          else
            echo "not running"
            exit 0
          fi
        fi
      else
        trap 'abort_cancel "" "0" "${tree:-}"' INT TERM HUP
      fi
      : > "$jd/cancelled"
      tree="$(job_tree "$pid" "$$")"
      is_win=0
      case "$(uname -s 2>/dev/null)" in MINGW*|MSYS*|CYGWIN*) is_win=1 ;; esac
      if [ "$is_win" -eq 0 ]; then
        # Freeze parents top-down BEFORE any child exits so parent shells (e.g. agy-handoff
        # or fallback loops) cannot wake on a killed child and spawn a new process, then
        # re-snapshot once (space-separated for BSD awk) to catch anything forked in between.
        while read -r p _; do
          [ -n "$p" ] && { kill -STOP "$p" 2>/dev/null || true; }
        done <<EOF
$tree
EOF
        roots="$(printf '%s\n' "$tree" | awk '{printf "%s ", $1}')"
        tree2="$(job_tree "$roots" "$$")"
        [ -n "$tree2" ] && tree="$tree2"
        while read -r p _; do
          [ -n "$p" ] && { kill -STOP "$p" 2>/dev/null || true; }
        done <<EOF
$tree
EOF
      fi
      trap - INT TERM HUP
      while read -r p w; do
        [ -n "$p" ] || continue
        if [ "$is_win" -eq 1 ] && [ -n "${w:-}" ] && [ "$w" != "-" ]; then
          case "$w" in
            *[!0-9]*) ;;
            *) MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' taskkill.exe /PID "$w" /T /F >/dev/null 2>&1 || true ;;
          esac
        fi
        kill "$p" 2>/dev/null || true
        [ "$is_win" -eq 0 ] && { kill -CONT "$p" 2>/dev/null || true; }
      done <<EOF
$tree
EOF
      for _ in 1 2 3; do
        alive=0
        while read -r p _; do
          [ -n "$p" ] || continue
          if kill -0 "$p" 2>/dev/null; then alive=1; break; fi
        done <<EOF
$tree
EOF
        [ "$alive" -eq 0 ] && break
        sleep 0.1 2>/dev/null || sleep 1
      done
      if [ "${alive:-0}" -eq 1 ]; then
        while read -r p _; do
          [ -n "$p" ] || continue
          if kill -0 "$p" 2>/dev/null; then
            kill -9 "$p" 2>/dev/null || true
            [ "$is_win" -eq 0 ] && { kill -CONT "$p" 2>/dev/null || true; }
          fi
        done <<EOF
$tree
EOF
        for _ in 1 2 3 4 5; do
          alive=0
          while read -r p _; do
            [ -n "$p" ] || continue
            if kill -0 "$p" 2>/dev/null; then alive=1; break; fi
          done <<EOF
$tree
EOF
          [ "$alive" -eq 0 ] && break
          sleep 0.05 2>/dev/null || sleep 1
        done
      fi
      echo "cancelled $(basename "$jd")"
    elif [ -f "$jd/cancelled" ]; then
      echo "already cancelled"
    else
      echo "not running"
    fi
    ;;
  ""|-h|--help|help)
    sed -n '/^# Usage:/,/^# Jobs live/p' "$0" | sed 's/^# \{0,1\}//' ;;
  *) die "unknown subcommand '$cmd' (start|list|status|result|cancel)" ;;
esac
