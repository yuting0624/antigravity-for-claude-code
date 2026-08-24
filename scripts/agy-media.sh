#!/usr/bin/env bash
#
# agy-media.sh — hand an audio / video / image file to Antigravity (`agy` / Gemini)
# and get back a TIMESTAMPED DIGEST, with the full transcript written to a file.
# Part of the "Antigravity for Claude Code" plugin.
#
# Why this exists: Claude Code can't hear audio or watch video, and adding that
# locally means ffmpeg + a speech model. Gemini is natively multimodal, so this
# delegates the perception work to agy — no local transcription stack needed.
#
# Cost discipline (the point): a 1-hour meeting is ~10k words. Pasting that into
# the conductor's context is exactly the `cache_read` blow-up the plugin exists to
# avoid. So agy writes the FULL transcript to a file and returns only a compact,
# timestamped digest; Claude ingests the digest and reads slices of the transcript
# only when it needs to verify something.
#
# Format pre-flight: agy's file→media handling is narrower than the Gemini API.
# Verified on agy 1.1.7: wav / mp3 / flac / ogg / mp4 / png work; m4a and aiff fail
# (inconsistently — "invalid argument" or a hang). Rather than let users hit that,
# this script checks the extension first and prints the exact conversion one-liner
# (or converts for you with --convert, using macOS afconvert or ffmpeg).
#
# Usage:
#   agy-media.sh <file> [focus/question] [options]
#
# Options:
#   -o, --out <path>      Where agy writes the full transcript
#                         (default: <file-dir>/<file-stem>.transcript.md)
#       --convert         Auto-convert an unsupported audio format to wav first
#                         (uses afconvert on macOS, else ffmpeg; writes next to the source)
#   -t, --tier <tier>     Delegation tier (default: pro — better at timestamps/diarization)
#       --timeout <dur>   agy print-timeout (default: 15m; long media needs headroom)
#       --print-command   Show the resolved agy-delegate call and exit (dry run)
#   -h, --help            Show this help
#
# Exit codes: 0 ok | 1 usage | 4 file not found | 5 unsupported format (convert first)
#             | otherwise the agy-delegate exit code (2 failed · 3 empty · 10 quota ·
#               11 auth · 12 timeout · 13 agy missing · 14 model · 15 permission)
#
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
DELEGATE="${AGY_DELEGATE:-$HERE/agy-delegate.sh}"

FILE=""; FOCUS=""; OUT=""; TIER="pro"; TIMEOUT="15m"; CONVERT=0; PRINT_CMD=0

die()   { echo "agy-media: $*" >&2; exit 1; }
need()  { [ "$1" -ge 2 ] || die "option '$2' needs a value"; }
usage() { sed -n '/^# Usage:/,/^# Exit codes:/p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

# Formats verified to work through agy headless (1.1.7).
is_supported() {
  case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
    wav|mp3|flac|ogg|opus|mp4|mov|webm|png|jpg|jpeg|gif|webp) return 0 ;;
  esac
  return 1
}
# Audio formats agy mishandles today but that convert cleanly to wav.
is_convertible() {
  case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
    m4a|aiff|aif|aac|caf|wma|amr) return 0 ;;
  esac
  return 1
}

while [ $# -gt 0 ]; do
  case "$1" in
    -o|--out)        need "$#" "$1"; OUT="$2"; shift 2 ;;
    --convert)       CONVERT=1; shift ;;
    -t|--tier)       need "$#" "$1"; TIER="$2"; shift 2 ;;
    --timeout)       need "$#" "$1"; TIMEOUT="$2"; shift 2 ;;
    --print-command) PRINT_CMD=1; shift ;;
    -h|--help)       usage ;;
    -*)              die "unknown option '$1'" ;;
    *)               if [ -z "$FILE" ]; then FILE="$1"; else
                       FOCUS="${FOCUS:+$FOCUS }$1"; fi; shift ;;
  esac
done

[ -n "$FILE" ] || die "no media file given (usage: agy-media.sh <file> [focus])"
[ -f "$FILE" ] || { echo "agy-media: file not found: $FILE" >&2; exit 4; }

# Absolute path: agy resolves the workspace, not our cwd.
ABS="$(cd "$(dirname "$FILE")" && pwd)/$(basename "$FILE")"
DIR="$(dirname "$ABS")"
STEM="$(basename "$ABS")"; STEM="${STEM%.*}"
EXT="${ABS##*.}"

# --- format pre-flight -------------------------------------------------------
if ! is_supported "$EXT"; then
  if is_convertible "$EXT"; then
    CONVERTED="$DIR/$STEM.wav"
    if [ "$CONVERT" -eq 1 ]; then
      echo "agy-media: converting .$EXT -> wav (agy mishandles .$EXT)…" >&2
      if command -v afconvert >/dev/null 2>&1; then
        afconvert -f WAVE -d LEI16@16000 -c 1 "$ABS" "$CONVERTED" >/dev/null 2>&1 \
          || die "afconvert failed converting '$ABS'"
      elif command -v ffmpeg >/dev/null 2>&1; then
        ffmpeg -loglevel error -i "$ABS" -ar 16000 -ac 1 "$CONVERTED" -y >/dev/null 2>&1 \
          || die "ffmpeg failed converting '$ABS'"
      else
        echo "agy-media: no converter found (need afconvert on macOS, or ffmpeg)" >&2
        exit 5
      fi
      ABS="$CONVERTED"; EXT="wav"
      echo "agy-media: converted -> $ABS" >&2
    else
      echo "agy-media: '.$EXT' is not reliably supported by agy (verified on 1.1.7: it fails with 'invalid argument' or hangs) — even though Gemini itself accepts it." >&2
      echo "agy-media: re-run with --convert, or convert once yourself:" >&2
      if command -v afconvert >/dev/null 2>&1; then
        echo "  afconvert -f WAVE -d LEI16@16000 -c 1 \"$ABS\" \"$CONVERTED\"" >&2
      else
        echo "  ffmpeg -i \"$ABS\" -ar 16000 -ac 1 \"$CONVERTED\"" >&2
      fi
      echo "agy-media: supported today: wav mp3 flac ogg opus | mp4 mov webm | png jpg webp" >&2
      exit 5
    fi
  else
    echo "agy-media: unrecognized media extension '.$EXT'." >&2
    echo "agy-media: supported: wav mp3 flac ogg opus | mp4 mov webm | png jpg webp" >&2
    exit 5
  fi
fi

[ -n "$OUT" ] || OUT="$DIR/$STEM.transcript.md"
case "$OUT" in /*) ;; *) OUT="$(cd "$(dirname "$OUT")" && pwd)/$(basename "$OUT")" ;; esac

# Size heads-up: long media is the usual cause of a timeout.
BYTES="$(wc -c < "$ABS" 2>/dev/null | tr -d ' ')"
if [ -n "$BYTES" ] && [ "$BYTES" -gt 26214400 ]; then
  echo "agy-media: note: $((BYTES / 1048576)) MB input — long media can exceed the model's window and the print-timeout. If it times out, split the file (e.g. ~30 min chunks) and run them separately." >&2
fi

# --- build the delegation prompt --------------------------------------------
# Contract: full transcript -> FILE; only a timestamped digest -> stdout (Claude).
IS_VISUAL=0
case "$EXT" in mp4|mov|webm|png|jpg|jpeg|gif|webp) IS_VISUAL=1 ;; esac
VISUAL_LINE=""
if [ "$IS_VISUAL" -eq 1 ]; then
  VISUAL_LINE="
- VISUALS: note what is on screen (scenes, slides, diagrams, UI, on-screen text/OCR) with timestamps; for a still image, describe it and transcribe any text."
fi

FOCUS_HINT=""
[ -n "$FOCUS" ] && FOCUS_HINT=" Focus especially on: $FOCUS."

PROMPT="Analyze the media file at $ABS.$FOCUS_HINT

STEP 1 -- write the full record to a file:
Write a complete, verbatim transcript to $OUT (create/overwrite it). Every line must start with a [mm:ss] timestamp (use [hh:mm:ss] past an hour). Attribute speakers as Speaker 1/2/... if more than one is audible. Do NOT put the full transcript in your reply.

STEP 2 -- reply with ONLY a compact digest (no full transcript, no raw dump):
- SUMMARY: 3-6 sentences on what this is and what matters.
- OUTLINE: the timestamped chapters/sections, one line each, as [mm:ss] topic.
- KEY POINTS: the load-bearing facts/decisions, each with its [mm:ss] source.
- QUOTES: up to 5 short verbatim quotes worth citing, each with [mm:ss].
- ACTION ITEMS / OPEN QUESTIONS: if any, each with [mm:ss] (say 'none' if none).$VISUAL_LINE
- NOTE any audio that was unclear/inaudible, and any names/numbers you are unsure of, with their [mm:ss] -- do not silently guess.
Finish with one line: DIGEST: <one-sentence takeaway>.

Transcript file: $OUT"

# --- delegate ----------------------------------------------------------------
# --yolo: agy needs tool permission to read the media file and write the transcript.
#
# Say what that costs, every time. GHSA-hwv2-vjgj-8rcv named this as a contributing
# factor and framed it as the containing directory — "picking one file exposes everything
# beside it". Measured, that is too small: --dir is where agy starts looking, not a
# boundary, and under --yolo it writes outside it. The grant is over the machine. None of
# that is obvious from "transcribe this recording", and the person choosing the file is
# the only one who can judge what is reachable from here.
#
# --sandbox was the candidate narrowing in 0.25.0 and it is NOT coming. It was deferred
# there because agy could not run; now it can, and the measurement says it does nothing:
# with --yolo, a write to an absolute path OUTSIDE --dir succeeded, `id` ran, and curl
# reached the network — identical with and without the flag. Adding it would have shipped
# something that reads as containment and provides none.
#
# The same measurement corrected this warning. 0.25.0 said "--dir exposes $DIR", which
# UNDERSTATES it: --dir is where agy looks first, not a boundary. --yolo approves every
# tool, and agy then writes wherever it likes.
NEIGHBOURS="$(ls -1 "$DIR" 2>/dev/null | grep -c . || echo 0)"
echo "agy-media: --yolo approves ALL agy tools for this run, including the terminal, so this is a grant over YOUR WHOLE MACHINE — not just $DIR ($NEIGHBOURS entr(y/ies) beside your file), which is only where agy starts looking. Measured: under --yolo, agy writes outside --dir and runs shell commands, and --sandbox does not change that. Run this on files you are willing to hand an unsupervised agent." >&2
ARGS=(--tier "$TIER" --yolo --dir "$DIR" --timeout "$TIMEOUT")
if [ "$PRINT_CMD" -eq 1 ]; then
  { printf 'agy-delegate'; printf ' %q' "${ARGS[@]}" "$PROMPT"; printf '\n'; }
  exit 0
fi

echo "agy-media: delegating $(basename "$ABS") to agy ($TIER, timeout $TIMEOUT); full transcript -> $OUT" >&2
"$DELEGATE" "${ARGS[@]}" "$PROMPT"
rc=$?

if [ "$rc" -eq 0 ] && [ ! -f "$OUT" ]; then
  echo "agy-media: WARNING — agy returned a digest but the transcript file was not created at $OUT. Verify before trusting the digest (agy may have skipped the write step)." >&2
fi
exit "$rc"
