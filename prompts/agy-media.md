---
description: Understand an audio / video / image file — Antigravity (agy/Gemini) transcribes and analyzes it, returning a timestamped digest while the full transcript goes to a file.
argument-hint: "<file> [what to focus on] [--convert] [--tier pro|flash] [--timeout 20m]"
---

Claude Code can't hear audio or watch video, and doing it locally means an ffmpeg +
speech-model stack. Gemini is natively multimodal — so **delegate the perception** to agy
and keep the judgment here.

Input: $ARGUMENTS

Do this:

1. **Resolve the file.** First arg is the path; anything else (that isn't a flag) is the
   focus/question. If no file was given, ask which one (AskUserQuestion) — don't guess.

2. **Delegate** (the engine handles format pre-flight, the digest contract, and writes the
   full transcript to a file):
   ```
   agy-media <file> [focus] [--convert] [--tier pro|flash] [--timeout 20m] [--out <path>]
   ```
   - Default tier is `pro` (better timestamps/diarization); `--tier flash` is fine for
     short/simple clips.
   - Long media needs headroom: raise `--timeout` (e.g. `20m`) for anything over a few
     minutes. If it still times out (exit 12), split the file into ~30-min chunks and run
     them separately.
   - **Exit 5 = unsupported format.** agy mishandles `.m4a` / `.aiff` (common for voice
     memos) even though Gemini accepts them. The engine prints the exact conversion
     command — re-run with `--convert` to have it converted automatically (macOS
     `afconvert`, else `ffmpeg`).

3. **Ingest ONLY the digest** it prints (summary · timestamped outline · key points ·
   quotes · action items · visuals · uncertainty notes). **Do not read the whole
   transcript file into context** — a 1-hour recording is ~10k words and re-reading it
   every turn is exactly the cost blow-up this plugin exists to avoid. The transcript file
   is there so you can grep/read *slices* on demand.

4. **Verify before you rely on it** (transcription is not ground truth):
   - Check the transcript file actually exists (the engine warns if it doesn't).
   - The digest flags unclear audio and uncertain names/numbers — **treat those as
     unverified**. For any load-bearing figure, name, or quote, read that timestamp's
     slice from the transcript file (e.g. `grep -n "\[12:3" <transcript>`) rather than
     trusting the summary.
   - Say plainly which claims you confirmed and which are still the model's guess.

5. **Report**: the digest's substance (not a re-paste), where the transcript lives, and
   what you verified. If the user asked a specific question, answer it with `[mm:ss]`
   citations so they can jump to the source.

Good uses: meeting/interview notes, a screencast or demo video, a voice memo, a
conference talk, a UI walkthrough, an architecture diagram or screenshot.
