---
description: Understand an audio / video / image / PDF file — the delegation server's `digest` tool reads it with a multimodal model and returns a timestamped, cited digest; the file never enters your context.
argument-hint: "<file> [what to focus on] [--tier pro|flash]"
---

Claude Code can't hear audio or watch video, and doing it locally means an ffmpeg +
speech-model stack. The `delegation` server's `digest` tool reads recordings, video,
images and long documents with a natively multimodal model and returns only a digest.

Input: $ARGUMENTS

Do this:

1. **Resolve the file.** First arg is the path; anything else that isn't a flag is the
   focus or question. If no file was given, ask which one (AskUserQuestion) — don't guess.

2. **Call** `digest({ file_paths: [<file>], focus?, question?, tier? })`. Recordings get a
   timestamped outline, action items, quotes, on-screen text and uncertainty notes;
   documents get page/section citations. `tier: "pro"` sharpens timestamps and speaker
   separation on long or noisy recordings; `flash` (default) is fine for most.
   Very large files are staged through the project's Cloud Storage bucket automatically.

3. **Ingest ONLY the digest.** Do not ask for a transcript into this conversation: a
   one-hour recording is ~10k words re-read on every turn, exactly the cost this plugin
   exists to avoid. If the user needs the full transcript, pass `save_transcript: true`
   and point them at the file the server writes.

4. **Verify before you rely on it** (transcription is not ground truth): the digest
   flags unclear audio and uncertain names or numbers — treat those as unverified, and say
   plainly which claims you confirmed and which are still the model's reading.

5. **Report** the digest's substance (not a re-paste), and answer the user's question
   with `[mm:ss]` or page citations so they can jump to the source.

Good uses: meeting or interview notes, a screencast or demo, a voice memo, a conference
talk, a UI walkthrough, an architecture diagram or screenshot, a long PDF.
