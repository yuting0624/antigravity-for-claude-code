# Changelog

All notable changes to **Antigravity for Claude Code**. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/); versions are in `.claude-plugin/plugin.json`.

## 0.22.3
- **The bash gate now says *why* it blocked** ([#51](https://github.com/yuting0624/antigravity-for-claude-code/issues/51),
  reported by @potch8228 with a six-case repro table that reproduced exactly).
  `hooks/validate-delegate-bash.sh` rejects an unquoted newline — correctly, since a bare
  newline separates commands in bash — but `BLOCK_MSG` was **one fixed string for every
  rejection**, and the header comment listed the metacharacters it rejects without mentioning
  newline. So a command refused for a stray trailing `\n` returned character-for-character the
  same message as one refused for not being `agy-delegate` at all. A caller could not tell
  "harmless formatting" from "you tried to run something else", and retried the same shape.
  The gate knew the reason at the moment it decided and threw it away. It now prints it to
  stderr — the path `BLOCK_MSG` already uses, which Claude Code feeds back to the agent —
  naming the newline and the remedy, the specific metacharacter, command substitution
  (including inside double quotes), an unterminated quote, a wrong `argv[0]`, too many pipes,
  or a non-allowlisted pipeline producer.
  **The reason never quotes ANY of the command back** — not even `argv[0]`. It lands in the
  agent's context and a blocked command routinely carries a delegation prompt; a character
  name and an offset are enough. `argv[0]` looks like a safe exception and is not: `head()`
  returns `shlex.split(seg)[0]`, the first shell *word*, so `"some prompt text" agy-delegate
  ...` makes attacker-chosen content `argv[0]`. Restricting it to name-shaped tokens does not
  help either — an API key is name-shaped. Caught by **both** PR reviewers, whose finding also
  exposed that the test written to cover it could not fail: it placed the marker after a valid
  `argv[0]` and behind a `;`, so the scan rejected the command first and the branch under test
  never ran. Five replacement cases now exercise the branches directly.
- **Leading and trailing whitespace is stripped before scanning.** Line 45 already computed
  `cmd.strip()` to test for emptiness and discarded it. bash ignores surrounding whitespace, so
  this cannot change what a command does, and a newline with nothing after it cannot begin a
  second one — it is the case you hit whenever a command is composed programmatically.
  **Internal newlines are untouched and still blocked**: `agy-delegate\n  "hi"` is genuinely two
  commands, so the reporter's case 6 does *not* flip, and neither does a newline after an
  unquoted pipe. Stripping also cannot rescue an unterminated quote.
  Not taken: allowing a newline immediately after an unquoted `|`. Safe in isolation, but it
  means editing the scanner's state machine rather than normalising before it — a different
  risk class on the one file that is the only restriction on what the delegate subagent may
  run, and change one already tells the caller how to fix it.
- Verified the block set did not move: 22 representative payloads produce identical verdicts
  before and after, and only the three intended whitespace cases flip. **23 new tests**
  (191 → 214): 11 fail against the gate as it was, 5 fail against this change's own first
  attempt, and the rest pin behaviour that must not regress — an internal newline, a newline
  after an unquoted pipe, an unbalanced quote, and an escaped backslash followed by a bare
  newline (which is *not* a line continuation, and which the first version of that test got
  wrong).

## 0.22.2
- **Correction: `--yolo` is not the only way to grant a headless write, and we said it was
  in eight places.** A `write_file(<dir>)` entry under `permissions.allow` in
  `~/.gemini/antigravity-cli/settings.json` grants writes **recursively beneath `<dir>`**
  with no flag at all. Confirmed on **agy 1.1.9** by @rickberguer with a controlled A/B
  ([#37](https://github.com/yuting0624/antigravity-for-claude-code/issues/37)): a covered
  target wrote, an uncovered one returned `PERMISSION_DENIED`, the rule the only variable.
  agy's own soft-deny message names the rule and offers `--yolo` as the *alternative* — the
  CLI had been saying this for a while and we had not.
  This matters beyond accuracy: we were recommending `--dangerously-skip-permissions`, which
  approves **every** tool, where a grant scoped to one directory subtree would do. `--yolo`
  is still what you need when no rule covers the target, and for web / Vertex AI Search /
  terminal / `define_subagent` — a `write_file` rule covers writes only.
  **The eighth place was the wrapper itself.** The write-task nudge fired immediately before
  a write that then succeeded, telling the user headless agy "will NOT write to your
  workspace without it". Corrected, along with the exit-15 message — which is exactly where
  someone lands after a denial and so is the best place to name the narrower fix. Also
  README, SKILL.md, POC-PLAYBOOK.md, TROUBLESHOOTING.md (both the fix list and the exit-code
  table), `commands/delegate.md` and the delegate subagent's own instructions.
  Scoped to what was actually measured: not verified below agy 1.1.9, and a glob form
  (`write_file(/path/**)`) was reported *not* to match. The wrapper cannot see
  `settings.json`, so the nudge stays a warning rather than a check — it just no longer
  asserts something false.
- Tests assert the wrapper offers the `permissions.allow` route on both the warning and the
  exit-15 path, and that it no longer claims `--yolo` is required. The warning assertion now
  matches a stable substring — that string has been reworded twice and an exact-phrase test
  breaks on prose edits rather than on behaviour.
- **Confirmed: the #37 hang fix clears the reporting environment.** 16 MCP servers (9 stdio,
  7 remote): `agy-doctor` 3.5s all-pass and a delegation round-trip in 6.7s, both previously
  hanging. The remote servers are spelled `serverUrl`, matching what 0.22.1's detector
  assumes.

## 0.22.1
- **Fix: every wrapper hung forever when stdio MCP servers were configured.** Reported by
  @rickberguer (#37) on macOS with a healthy, authenticated agy. `agy`'s stdio MCP children
  **inherit its stdout and outlive it**, so they hold the write end of a command-substitution
  pipe open and `OUT="$(agy ...)"` never sees EOF. **The wall-clock guard cannot help**: it
  kills `agy`, not the grandchildren — which is why this presented as an unbounded hang
  despite the timeout that exists for exactly this class of problem. Isolated cleanly by the
  reporter: same machine, only `mcp_config.json` changed — 16 servers hung on a pipe and
  returned in 6.5s to a file; 0 servers returned in 5.6s either way.
  Blast radius was everything. `doctor` hung inside `agy_guard`, so `/antigravity:setup`
  reported a broken or unauthenticated CLI while auth was fine, and `agy-delegate` hung on
  every call, taking `agy-job`, `delegate`, `review`, `research` and the delegate subagent
  with it.
  `agy` stdout now goes to a temp file, which children inherit harmlessly — the main call,
  and the `agy --help` capability probe, which had the same hazard and was not in the report
  (that line has now been wrong twice, for two unrelated reasons; see 0.21.1). Cleanup is
  folded into the existing `EXIT` trap, so it also happens on the timeout path where a
  trailing `rm -f` never runs. `doctor`'s `agy_guard` redirects internally and `cat`s at the
  end, so `cat` is the only writer to the caller's pipe and it always exits. `agy-job.sh`
  already redirected to files and needed no change.
  Guarded by shape, not symptom — a hang cannot be asserted on cheaply and the next refactor
  is where it returns: tests reject any command-substitution capture of `agy` in either
  script, plus a stub that reproduces the inherited-stdout hang and shows the file form
  returning. All verified to fail against the unfixed code.
- **`doctor` now names stdio MCP servers when `agy models` times out.** The precondition is
  invisible from the plugin's side and currently reads as an auth failure, which sends people
  off re-authenticating for nothing. Counts **both** sources agy documents — the global
  `~/.gemini/config/mcp_config.json` *and* `plugins/<name>/mcp_config.json` — because a
  diagnostic that undercounts fails silently, for exactly the person it exists for. Remote
  servers are identified by `serverUrl` on agy 1.1.9, not the `url`/`httpUrl` other MCP
  clients use. The hint describes agy **blocking internally on a server that never finishes
  connecting** — which reproduces with stdout on a file and is what can still hang here —
  not the pipe mechanism this release removes.

## 0.22.0
- **Docs: the number of delegations is the lever — batch them.** Benchmarking this
  plugin (Opus 5 conductor · Gemini 3.6 Flash High executor · agy 1.1.8 · n=3/arm, cold
  cache) confirmed the per-delegation economics and located what actually breaks them.
  Offloading a large corpus worked as designed — the conductor's `cache_read` fell **61%**,
  it never opened the corpus itself, each digest came back at ~4k tokens — but **each
  `agy-delegate` call is an independent session sharing no cache with the last**, so a
  conductor that delegated 7.3× against the same corpus paid to ingest it 7.3×.
  **Two-thirds of the executor's cost was re-reading material it had already read**;
  break-even was ~5.7 delegations.
  **Correction to shipped guidance:** rule 6 told you to keep an agy session alive with
  `--continue` so the working context "lives on the cheap side". Measured, that is
  backwards — resuming carries the whole prior conversation forward *and* agy re-reads the
  material anyway, so the continued call cost **+82% / +277%** vs a fresh one (n=2), with
  `cache_read` 3–14× higher. `--continue` is for resuming after a quota/timeout failure,
  not a cost lever. The only lever that actually removes a re-ingestion is folding related
  units into one fully-specified delegation (rule 4). Also recorded: delegation **moves** work
  rather than removing it (~2.8× the normalized token volume for the same result), and
  agy's own prompt cache covers only ~2/3 of its context re-reads — both push toward
  fewer, larger delegations. Stated as direction from one configuration, not as constants.
- **`AGY_USAGE_LOG` — a side channel the conductor's own habits can't truncate.**
  `AGY_USAGE`/`AGY_SIGNAL` go to stderr, but this skill tells the conductor to keep its
  context lean, so it writes `agy-delegate ... 2>&1 | tail -N`; stdout (the digest) is
  emitted *after* the usage line, so `tail` keeps the digest and drops the usage. Measured
  in the wild: a benchmark harness lost most of its Gemini-side cost data this way, making
  the hybrid look cheaper than it was. Set `AGY_USAGE_LOG=/path` (or the `usage_log`
  option) and both line types are appended to that file as well. Appends (never
  truncates), off by default, and an unwritable path is non-fatal — measurement must not
  break the work.
- **`agy-trace` now covers plain delegations, not just internal-fan-out subagents.**
  Every agy run leaves a readable `transcript.jsonl`, and `agy-delegate` prints the
  `conversationId` in `AGY_USAGE`, so cost and trajectory join 1:1 (verified 10/10 in the
  benchmark). New **`--audit`** (step-type counts + every non-zero exit) and **`--last`**.
  This makes the skill's non-negotiable "never trust agy's self-reported GREEN" rule
  actually checkable: measured, a delegation reported SUCCESS while **6 commands inside it
  failed**. Documented limit: the command **strings** are recorded nowhere (not in
  `transcript.jsonl`, `transcript_full.jsonl`, or `cli-*.log`) — you get that a command
  ran, its exit code and its output; to attribute a filesystem change, diff the tree.
- **Fix: structured-error classification broke on any error containing quotes.** agy
  quotes the offending value in its message (`invalid model selection (--model \"X\" ...):
  model X is not recognized as a known model`), and the wrapper pulled the `error` field out
  with `sed 's/.*"error": *"\([^"]*\)".*/\1/'` — which stops at that first escaped quote,
  discarding the diagnostic phrase that follows it. The classifier therefore never saw it:
  a bad `--model` or `tier_*` remap reported a generic **"agy failed" (exit 2)** instead of
  **MODEL_UNAVAILABLE (exit 14)** with the "run `agy models`" hint. Present since 0.21.0,
  i.e. the structured-output release existed to stop exactly this kind of misclassification.
  python now writes the raw error to its own file instead of it being re-parsed with sed.
  The old stub's error string had **no embedded quotes**, which is why the suite stayed
  green while this shipped — the new stub uses agy's real wording.
- **`prices.json`: recorded Gemini 3.6 Flash's rates without repricing the shipped
  default.** The VM confirmed 3.6 Flash output at **7.50/M** (vs 3.5's 9.00; in and
  cached-in unchanged) — but `agy-cost-compare.sh` picks the `gemini_flash` key by **tier
  name**, and `model_for_tier()`'s `flash` tier still resolves to **Gemini 3.5 Flash
  (High)**. So `gemini_flash` stays at 9.00, which is correct for what ships, and 3.6's
  rates live in a new `gemini_flash_36` for anyone who remaps `tier_flash`.
  *(An earlier commit in this branch changed `gemini_flash.out` to 7.50 and asserted 3.6
  was the default — contradicting this same PR's SKILL.md text, and understating Gemini
  output by 17% out of the box. Caught in review.)*
  Also added `cached_in` (Gemini prices cached input at a flat rate — *not*
  `cache_read_mult × in`, which is Claude-deck only) and a note that Gemini's
  context-cache **storage** is time-billed and unreported by agy, so figures computed
  here are a **lower bound**. `cached_in` has no consumer yet: `measure-session.py`
  prices the orchestrator deck only.
  Two tests now hold this together: every hardcoded fallback in `agy-cost-compare.sh`
  must match `prices.json`, and `gemini_flash` must match whatever the `flash` tier
  actually resolves to.
- **Docs: Gemini 3.6 Flash High measured against 3.5.** −23% input tokens for the same
  task (n=2, order-reversed) and output at $7.50/M vs $9.00/M — but it does **not** reduce
  `cache_read` (+6%) and is ~29% slower. `flash-medium` is −31% input / −21% wall but
  **`cache_read` +43%** (n=3, reproduced), so it loses on cache_read-dominated agentic
  work. The `flash` default stays on 3.5 for plan availability; remap `tier_flash` to
  `gemini-3.6-flash-high` when your plan serves it.

## 0.21.1
- **Fix: the JSON-mode capability probe could silently disable structured output
  (SIGPIPE race).** `agy-delegate.sh` probed support with
  `agy --help 2>&1 | grep -q -- '--output-format'`. `grep -q` exits at the first match and
  closes the pipe, so `agy --help` can die of **SIGPIPE (141)**; under `set -o pipefail`
  the whole pipeline reads as *failed*, JSON mode stays off, and **no `AGY_USAGE` line is
  emitted** — which is indistinguishable from "no delegation happened". Measured on a
  loaded container during a benchmark run: **~75% of calls** lost their usage line
  (2/25 locally under no load). The probe now captures `agy --help` once into a variable
  and matches with a shell glob — no pipe, no `grep`, no race. Regression tests assert
  both the absence of the pipe and 20 stable probes.
  *(Found by @yuting0624's benchmark harness — exactly the "silent success" failure class
  this plugin exists to catch elsewhere.)*
- **Docs: corrected the `AGY_USAGE` accounting semantics.** `total = input + output`
  (`thinking` is inside `output`), and **`cache_read` is a separate counter — not part of
  `total`, and not a subset of `input`**: in an agentic delegation it can far exceed
  `input` (measured 1,356,694 vs 243,117). Price the Gemini side as three separate terms.
  This is the opposite convention from the Claude/Harbor side, where cache-read tokens
  *are* an inner subset of the input total. An earlier note in 0.21.0 stated the subset
  reading; that was over-concluded from a sample where `cache_read < input`.

## 0.21.0
- **Structured output (agy 1.1.8): reliable failure classification + real executor token
  usage.** agy 1.1.8 shipped `--output-format json` — the thing we'd tracked as "not
  externally available" since 0.13. The wrapper now uses it **internally**, and the
  **stdout contract is unchanged** (callers still get the model's text):
  - **Failures are classified from the structured `status`/`error`** instead of
    pattern-matching prose. This matters: agy's stderr wording has shifted repeatedly
    (the same failure surfaced as both "invalid argument" and a hang), and in JSON mode
    stderr is empty — the diagnostic moves into the envelope. The wrapper reads the
    envelope first and still falls back to stderr patterns.
  - **New `AGY_USAGE {...}` line on stderr** with the executor's real token accounting —
    `input` / `output` / `thinking` / **`cache_read`** / `total` + `conversation_id`.
    The Gemini side of a delegation can now be **measured, not estimated** (stderr, so it
    never pollutes the conductor's context).
  - **Gated and reversible**: only when agy advertises `--output-format`, `python3` is
    present, and the new `structured_output` option isn't `off` — otherwise the
    dependency-free plain-text path runs unchanged. Tests cover both paths.
  - Verified live on agy 1.1.8 (success, model-unavailable → exit 14, opt-out), plus
    stubs for quota/fallback.
- **Upstream caveat found while implementing**: agy 1.1.8 emits a **raw newline inside the
  `response` string**, so the payload is rejected by strict JSON parsers. The wrapper
  parses leniently; worth reporting upstream.
- Docs corrected everywhere they claimed `--output-format json` doesn't exist (README,
  SKILL) — that statement is no longer true as of agy 1.1.8.

## 0.20.0
- **New: multimodal delegation — `/antigravity:media` (`agy-media`).** Claude Code can't
  hear audio or watch video, and doing it locally means an ffmpeg + speech-model stack.
  Gemini is natively multimodal, so this delegates the perception to agy — **no local
  transcription stack required**. Verified end to end on agy 1.1.7 (audio transcribed;
  video analyzed with per-scene visuals + OCR + speech).
  - **Cost discipline built in (the differentiator):** agy writes the **full timestamped
    transcript to a file** and returns only a compact **digest** (summary · timestamped
    outline · key points · quotes with `[mm:ss]` · action items · visuals · uncertainty
    notes). A 1-hour recording is ~10k words — exactly the `cache_read` blow-up the plugin
    exists to avoid, so it never lands in the conductor's context; Claude reads *slices* of
    the transcript on demand to verify.
  - **Format pre-flight:** agy's media handling is narrower than the Gemini API. Verified
    working: `wav mp3 flac ogg opus | mp4 mov webm | png jpg webp`. **`.m4a` / `.aiff`
    fail** (inconsistently — "invalid argument" or a hang) despite Gemini itself accepting
    them — an agy-side gap. Rather than surfacing that cryptic failure, the engine checks
    the extension first, exits `5` with the exact conversion one-liner, and `--convert`
    does it for you (macOS `afconvert`, else `ffmpeg`).
  - **Verification framing:** the digest must flag inaudible passages and uncertain
    names/numbers; the command tells Claude to treat those as unverified and check the
    transcript slice before relying on them. Warns if agy returns a digest without
    actually writing the transcript file.
  - Long media: default `--timeout 15m`, size heads-up over 25 MB, and guidance to split
    (~30-min chunks) if it still times out.

## 0.19.0
- **Security: harden the delegate subagent's Bash gate against command-injection bypass**
  ([#29](https://github.com/yuting0624/antigravity-for-claude-code/issues/29), reported by
  **@ktseo41**). `hooks/validate-delegate-bash.sh` is the *only* restriction on what the
  `antigravity-delegate` subagent can run via Bash; it matched the wrapper name as a
  **substring anywhere in the command**, so payloads like `... # agy-delegate` or
  `echo $(...) agy-job` were approved — arbitrary command execution under prompt injection.
  The gate now:
  - requires the **first command token** (argv[0], basename, optional `.sh`) to be exactly
    `agy-delegate` / `agy-job` — a token check, not a substring match;
  - allows only one pipeline shape, `<git|cat|echo|printf> | agy-delegate|agy-job -`
    (so `git diff | agy-delegate -` keeps working);
  - rejects **unquoted** `;` `&` `|` `<` `>` `(` `)` `#`, backticks, and `$(` (command
    substitution) — while permitting those characters **inside a quoted prompt** (no false
    positives on legitimate prompts; `$(...)`/backticks inside double quotes are still
    blocked because bash would expand them);
  - **fails closed** (block) if the JSON is unparseable or `python3` is unavailable (the
    old fallback matched against the raw JSON, which was fail-open-ish).
  - Regression tests cover both the bypass vectors and legitimate-usage false positives.
- **Added `SECURITY.md`** with a private vulnerability-reporting channel (the reporter
  noted its absence). Report via GitHub Security advisories.

## 0.18.4
- **`bin/measure-session` shim** — `measure-session.py` was the only script without a `bin/`
  entrypoint, so it couldn't be run by bare name from a marketplace install (only via the
  `scripts/` path, which doesn't resolve from a user's own repo). It now has a shim like the
  others, so `measure-session <session-id>` works on the PATH. (`doctor` + contract tests
  cover it.)
- **Fan-out recipe corrected for agy 1.1.3+.** The skill's internal fan-out example now
  leads with the preferred `define_subagent → invoke_subagent` form and **requires `--yolo`**
  — on 1.1.3+ the subagent tools are soft-denied headless without it (the old "spawning needs
  no `--yolo`" note was 1.0.x behavior). Re-verified live on 1.1.5 (two parallel subagents,
  each with an auditable `transcript.jsonl` via `agy-trace`).

## 0.18.3
- **`doctor` fix — recognize tier models across `agy models` format changes.** agy 1.1.5
  switched `agy models` output from **display names** (`Gemini 3.5 Flash (High)`) to
  **slugs** (`gemini-3.5-flash`), which broke doctor's strict `grep` and made it **falsely
  warn that every tier model was missing** (they still work). doctor now normalizes both
  sides (lowercase-alphanumeric, bidirectional substring), so it survives either format.
- **Verified against agy 1.1.4 / 1.1.5.** Default `flash` delegation, tier resolution, and
  exit-code classification all work on 1.1.5 (1.1.4/1.1.5 were mostly interactive/UX:
  `--effort`, stable model slugs, `/model` picker, MCP fixes).
- **Gemini 3.6 Flash** now appears in `agy models` and **works** (verified all effort
  variants through the wrapper). The `flash` **default stays Gemini 3.5 Flash (High)** for
  broad plan availability (newer models can lag on enterprise Vertex) — remap `tier_flash`
  to `Gemini 3.6 Flash (High)` if your plan serves it. (Both display names and 1.1.5 slugs
  are accepted by `--model`.)
- **Still unchanged upstream** (re-confirmed on 1.1.5): headless writes need `--yolo` (a
  `permissions.allow` write-rule was still soft-denied in testing despite 1.1.4's
  "honor settings.json headless"), `--output-format json` not externally available yet,
  native Windows headless (`#508`/`#6`) unresolved.

## 0.18.2
- **agy 1.1.3: headless write model changed again — `--yolo` is now the durable grant.**
  All verified live on 1.1.3:
  - 1.1.3 **removes the scratch-divert**: a write/tool needing permission is now
    **soft-denied** in headless mode with a clear stderr notice (rc=0 + empty stdout).
    This is the upstream's intended behavior (announced), not a bug — the evolved issue #10.
  - **`--mode accept-edits` no longer grants headless writes** (soft-denied for create AND
    edit on 1.1.3 — it had been riding the auto-approve behavior that 1.1.3 closed). Docs,
    the `delegate` command, and the write-task warning now point to **`--yolo`** as the
    reliable headless write/tool grant across versions; `--mode` passthrough stays but is
    no longer recommended for writes.
  - **New structured failure `15` — permission denied**: the wrapper detects the soft-deny
    stderr (rc=0 + empty) and returns exit `15` + `AGY_SIGNAL {PERMISSION_DENIED}` with an
    actionable message ("add `--yolo`"), instead of a bare "empty output". `agy-job`
    renders it.
  - Note: `--output-format json` is **still not externally available**, and native Windows
    headless (`#508`/`#6`) is **still unresolved** — WSL guidance and plain-text parsing stay.

## 0.18.1
- **New structured failure `14` — model unavailable** (agy 1.1.2): agy now **hard-fails**
  (instead of silently downgrading to the default model) when `--model` can't be resolved.
  The wrapper classifies this into exit `14` + `AGY_SIGNAL {MODEL_UNAVAILABLE}` and prints
  an actionable hint (run `agy models`; fix `--model` / `tier_*` / `default_model`) — the
  common failure when a tier remap points at a model your plan doesn't expose. `agy-job`
  renders the new code.
- **Note on agy 1.1.x upstream fixes** (verified against release notes): 1.1.1 fixed
  `agy -p` hanging inside a subprocess/script and print mode silently exiting success on a
  server-side error; both are now non-zero + stderr, so the wrapper classifies them
  correctly. Native Windows headless (`#508`/`#6`) is **still not resolved upstream**, and
  `--output-format json` is **still not externally available** — the WSL guidance and
  plain-text parsing stay.

## 0.18.0
- **agy 1.1.0 support — `--mode accept-edits|plan` passthrough** (all behaviors below
  verified live on 1.1.0):
  - 1.1.0 makes **review-first** the default execution mode. Headless consequence
    (measured): a write task **without** write permission no longer just "describes" —
    agy writes the files to its **own scratch dir** (`~/.gemini/antigravity-cli/scratch`)
    and reports success, while your workspace stays untouched (the evolved #10 failure
    mode).
  - New wrapper flag **`--mode accept-edits`**: auto-applies FILE EDITS to the real
    workspace *without* granting terminal/tool permissions — a **narrower grant than
    `--yolo`**, now the recommended way to run pure write delegations. `--yolo` remains
    for tasks that also need tools (web / Vertex AI Search / terminal); verified
    backward-compatible on 1.1.0. `--mode plan` passes through for strategize-only runs.
  - The write-task warning now fires only when *neither* `--mode accept-edits` nor
    `--yolo` is set, and explains the scratch-divert behavior.
  - Subagents re-verified on 1.1.0 (`define_subagent` → `invoke_subagent`, transcript
    path unchanged); they are **officially documented** as of 1.1.0, with static config
    at `<workspace>/.agents/agents/*.md` and global `~/.gemini/config/agents/` — the
    skill's fan-out recipe now points at the official docs.
  - `delegate` command, skill safety section, and README write guidance updated to the
    "prefer `--mode accept-edits`, escalate to `--yolo` only for tools" split.

## 0.17.0
- **Frictionless delegation — no slash command required, judgment stays with Claude.**
  Two additions reduce the "you must type `/antigravity:delegate` every time" friction,
  while deliberately NOT auto-routing (full automation below the break-even is a
  measured net loss):
  - **Proactive subagent selection**: the `antigravity-delegate` description now tells
    Claude to use it *proactively* for bulk work (scaffolding / exhaustive tests /
    migrations / fan-out search) — with the explicit counterweight that the break-even
    judgment is Claude's, every time.
  - **Prompt-level nudge** (`hooks/nudge-delegation.sh`, UserPromptSubmit): a cheap,
    deterministic heuristic (volume/fan-out phrases, EN + JA) adds a short advisory note
    when a prompt looks above the break-even. Advisory material only — the note itself
    says "THE JUDGMENT IS YOURS". Only the `prompt` field is scanned (no cwd/path false
    positives), the user's prompt is never echoed back (no injection surface), and it
    stays silent when the user is already delegating. Toggle via the new
    `delegation_nudge` plugin option.

## 0.16.1
- **Internal fan-out recipe updated for agy 1.0.16** (re-verified per the recipe's own
  "re-verify after upgrades" caveat — which became real within a day): **dynamic custom
  subagents now work** — `define_subagent` a named specialist in-session, then
  `invoke_subagent` it by TypeName (1.0.13–1.0.15 shipped this broken, upstream #521;
  fixed in 1.0.16 via the JSON→Markdown definition change). The `self`+Role pattern
  stays as the any-version fallback (re-verified on 1.0.16). `transcript.jsonl`
  location is unchanged across 1.0.12→1.0.16, so `agy-trace` is unaffected. The recipe
  now flags the whole surface as fast-moving (4 upstream releases in a week; official
  static agent-config docs drift from behavior, upstream #527).

## 0.16.0
- **Internal fan-out recipe + `agy-trace`** (community pointer to upstream
  antigravity-cli#105; **verified headless on agy 1.0.12**): agy's `invoke_subagent`
  sandbox only allows TypeNames `self`/`research` — custom TypeNames are rejected. The
  skill now documents the **role-delegation pattern** (TypeName `self` + a specialist
  `Role`) for one-delegation internal fan-out, so coordination tokens land on the cheap
  (Gemini) side instead of the frontier side. Spawning needs no `--yolo` (writes inside
  the work still do).
  - Each spawned subagent leaves a **readable step-by-step `transcript.jsonl`** under
    `~/.gemini/antigravity-cli/brain/<conversationId>/` — unlike the opaque conversation
    `.db` blobs. New **`agy-trace`** (script + bin shim) pretty-prints one (`agy-trace
    <conversationId>`), lists recent ones (`--list`), or emits raw JSONL (`--raw`) so
    Claude can run a real trajectory audit on what subagents actually did.
  - Skill's trajectory-check gate updated accordingly; `doctor` covers the new script/shim.
- **`--digest` flag + digest-size guard** — the cost discipline's biggest lever ("ingest
  digests, not dumps") is now enforced in code, not just prose
  ([#5](https://github.com/yuting0624/antigravity-for-claude-code/issues/5)):
  - `agy-delegate --digest` appends a digest-only **output contract** to the prompt
    (compact bullets + a one-line `DIGEST:` trailer; no full files / raw logs).
  - The wrapper now **warns on stderr when a reply comes back dump-sized** (default
    threshold 8000 chars) so the conductor doesn't silently ingest a raw dump. New plugin
    option `digest_warn_chars` tunes it (`0` disables).
  - `delegate` command + skill updated to use `--digest` for bulk reads and to not ingest
    a flagged dump.
- **Support docs — one-round-trip diagnosis**: every environment bug so far (#6, #10,
  #11, #15) needed the same three facts, so they're now asked up front:
  - **Issue templates** (`.github/ISSUE_TEMPLATE/`): the bug form requires `agy-doctor`
    output, OS/platform, and install method (marketplace vs `--plugin-dir`).
  - **`docs/TROUBLESHOOTING.md`**: symptom-first fixes — Windows headless hang (and the
    "agy works when I type it" console explanation), WSL `/mnt` slowness, silent
    no-write without `--yolo`, exit-code/`AGY_SIGNAL` table, tier remaps, updating.

## 0.15.1
- **Injected routing policy no longer references `$CLAUDE_PLUGIN_ROOT`**
  ([#15](https://github.com/yuting0624/antigravity-for-claude-code/issues/15), fix by
  **@Masterisk-F** in #16): the SessionStart `additionalContext` in
  `hooks/policy-context.json` still told the model to run
  `"$CLAUDE_PLUGIN_ROOT/scripts/agy-delegate.sh"` — but that variable isn't exported to
  model-run Bash (same root cause as #11), so it expanded empty and the model had to
  rediscover the `bin/` entrypoint. Now uses the bare `agy-delegate` bin name. (The #11
  bin/ migration updated commands/skill/agents but missed this injected string.)
  - This ships as a **version bump** so `/plugin marketplace update` recognizes the fix —
    #16 landed on `master` without one, leaving installs on 0.15.0 unable to see it.
- **Regression guard widened**: the contract test now also fails if any SessionStart
  `additionalContext` references `$CLAUDE_PLUGIN_ROOT` (not just commands/skill markdown),
  so this class of bug can't recur in injected context.
- **Version-drift guard**: the contract test now asserts `SKILL.md`'s `version:` matches
  `plugin.json` — they had drifted (skill stuck at 0.14.0 while the plugin was 0.15.0);
  re-synced to 0.15.1.

## 0.15.0
- **New command — `/antigravity:cloud-run-debug`** (Conductor/Executor demo): diagnose a failing
  Cloud Run service. agy (Gemini) does the bulk, cheap work — pulling `severity>=ERROR` logs via
  `gcloud logging read` and clustering them into a structured digest (error clusters /
  representative stack traces / time distribution / likely root-cause candidates) — and Claude
  ingests only that digest to infer the root cause and propose a fix. The lean handoff keeps
  Claude's context (and cost) down.
  - **Read-only by default** — diagnosis + proposal only. `--apply` is the only write path, and it
    only ever lands the fix on a dedicated branch with the diff shown for a human to review/merge;
    nothing is deployed or merged automatically.
  - **Narrow surface, generic engine:** one user-facing command, but the engine
    (`scripts/cloud-debug.sh`, shimmed as `bin/cloud-debug`) takes `--resource-type` (default
    `cloud_run_revision`) so a future gke-/functions-debug can reuse it without a rewrite. The
    digest reuses `agy-delegate.sh` — no new delegation logic.
  - **Safety:** uses the existing `gcloud` ADC (never asks for tokens); a missing
    `roles/logging.viewer` exits with the exact `add-iam-policy-binding` fix.
  - **`--apply` dirty-tree guard + project visibility:** before branching, `--apply` checks
    `git status --short` and stops if the tree is dirty (so a user's uncommitted changes can't
    leak into the fix's diff/commit); and `--project` is now a surfaced flag, with the command
    confirming the resolved project when it isn't passed (avoids reading the wrong GCP project).
  - **Lean by construction:** the log payload handed to agy is field-projected
    (`--format='json(timestamp,severity,textPayload,jsonPayload,httpRequest.status)'`,
    dropping resource/insertId noise ~5-10x) and byte-capped before the handoff
    (`CLOUD_DEBUG_MAX_BYTES`, default 200000; the tail is clipped — byte-accurate
    across locales, so multibyte logs are bounded too — and agy is told the clipped
    JSON is partial/invalid) — so the "cheap / lean handoff" claim holds even on
    noisy services where `--limit` alone bounds entry *count* but not byte volume.
  - `doctor` checks the new script/shim; `tests/` stub `gcloud` + `agy` and cover the
    fetch→digest, default `--since`, read-only (no writes / no `--apply` in the engine), and
    permission-denied paths.

## 0.14.0
- **`bin/` entrypoints — fixes `$CLAUDE_PLUGIN_ROOT` failures on marketplace installs**
  ([#11](https://github.com/yuting0624/antigravity-for-claude-code/issues/11)):
  `$CLAUDE_PLUGIN_ROOT` is only substituted in structured config (hooks/MCP/LSP) and is
  **not** exported to model-run Bash — so commands/skills that ran
  `"$CLAUDE_PLUGIN_ROOT/scripts/…"` expanded to an empty path and failed. Scripts are now
  invoked by **bare name via `bin/` shims** (Claude Code adds a plugin's `bin/` to the
  Bash-tool PATH): `agy-delegate` / `agy-job` / `agy-cost-compare` / `agy-doctor`. Commands,
  the skill, and the delegate subagent were updated; the PreToolUse gate accepts the bin
  names; `doctor` checks the shims. (`scripts/` is unchanged — the shims forward to it.)
- **Write-delegation guidance + guard**
  ([#10](https://github.com/yuting0624/antigravity-for-claude-code/issues/10)): without
  `--yolo`, headless agy only *describes* edits and returns a confident success **while
  writing no files**. The `delegate` command now makes `--yolo` explicit for write tasks
  (on a branch), notes the harness may prompt for / block `--dangerously-skip-permissions`,
  and flags the ~2-min sync Bash limit (→ background job). `agy-delegate.sh` now warns when a
  write-looking prompt lacks `--yolo`. (The verification gate already caught the no-write.)
- Thanks to **@erszcz** (#10) and **@Masterisk-F** (#11) for the reports.

## 0.13.0
- **Windows headless hang fixed / diagnosed** ([#6](https://github.com/yuting0624/antigravity-for-claude-code/issues/6)):
  on native Windows without a console (ConPTY), headless `agy -p` / `agy models` could
  hard-hang with a 0-byte log when stdio is redirected.
  - **`agy-delegate.sh`**: wraps agy in a wall-clock guard (GNU `timeout`/`gtimeout`,
    with `--kill-after`) sized from `--timeout` + head-room, so a hang now returns a
    structured **TIMEOUT (exit 12)** + `AGY_SIGNAL` instead of blocking forever. Warns on
    native Windows when no `timeout` binary is available.
  - **`doctor.sh`**: `agy models` (and the version probe) are now time-bounded and **distinguish a hang from an
    auth failure** — it no longer tells you to re-authenticate when agy is actually hung
    headless (the misdiagnosis that cost the reporter hours). A genuine empty result still
    reports "not authenticated".
  - **README**: added a Platform-support note (macOS/Linux/WSL supported; native Windows
    not recommended for headless delegation) and a known-limit entry.
  - **tests**: added a hang → wall-clock-guard → exit 12 case (skips cleanly without `timeout`).
  - Thanks to **@rokushikii** for the detailed, reproducible report.

## 0.12.0
- **Configurable executor model** (agy is multi-model): tiers still default to Gemini, but
  each is remappable to any `agy models` entry (Claude/GPT on plans that expose them) via
  `tier_flash` / `tier_flash_lo` / `tier_pro`, plus a `default_model` (exact name) option —
  all `CLAUDE_PLUGIN_OPTION_*`. Precedence: `--model` > explicit `--tier` > `default_model`
  > default tier. Keeps Gemini as the recommended default (a different/cheaper executor is
  what yields the cost + cross-model-verification benefit).
- **doctor**: tier-model check now respects the remaps and **warns instead of failing** when a
  model isn't in `agy models` (agy is plan-dependent), with a remap hint.
- (Reported via Reddit: agy supports Claude/GPT on non-Vertex plans.)

## 0.11.1
- **WSL slow-mount guard**: `agy-delegate.sh` warns when `--add-dir` targets a Windows
  mount (`/mnt/*`) under WSL — agy reads it over a slow 9p bridge, so even trivial calls
  can take 20s+ — and `doctor` flags a workspace on `/mnt/*`. Fix: keep the repo on the
  WSL Linux filesystem (`~`). Also documented in known-limits. (Reported via Reddit.)

## 0.11.0
- **Auto-injected routing policy** (`hooks/`): a `SessionStart` hook injects the
  plugin's **cost-aware** routing policy as session context (delegate above the
  break-even, keep Claude's context lean, always verify) so the discipline applies
  without invoking the skill. Toggle via the `coding_policy` plugin option. A second
  hook does a fast `agy` presence/auth check on session start.
- **Delegation subagent** (`agents/antigravity-delegate.md`): `tools: Bash, Read, Glob`
  with a `PreToolUse` gate (`hooks/validate-delegate-bash.sh`) that permits only the
  delegation wrapper — no `Write`/`Edit`, no arbitrary Bash — so file *writing* runs on
  agy/Gemini (no Claude tokens spent generating file contents); it returns a digest for
  Claude to verify.
- **Structured exit codes + signal**: `agy-delegate.sh` now classifies failures into
  `10` quota · `11` auth · `12` timeout · `13` agy-missing and prints a machine-readable
  `AGY_SIGNAL {...}` line; `agy-job.sh` surfaces the code/label/signal in `status`/`result`.
- **Plugin options** (`userConfig`): `default_tier`, `timeout`, `coding_policy` — read by
  the wrapper/hook via `CLAUDE_PLUGIN_OPTION_*` (explicit flags still override).
- **`/antigravity:research`** command: surfaces the skill's Claude-orchestrated deep-research
  recipe — agy fans out grounded web search (compact digests), Claude verifies each
  load-bearing claim across ≥2 independent sources and synthesizes a cited report.
- **`--print-command`** (agy-delegate dry run): prints the resolved `agy …` invocation
  without executing — for debugging/trust; works even without agy installed.
- **Plugin-contract test**: asserts the manifests, that every hook/agent file reference
  resolves, command/skill/agent frontmatter is present, and hook scripts are executable —
  catches a broken reference before release.
- **CI**: shellcheck + JSON validation now also cover `hooks/`.

## 0.10.0
- **Pricing config** (`prices.json`): single source of current Vertex rates (Opus 4.8
  5/25, Sonnet 4.6 3/15, Gemini 3.5 Flash 1.50/9, Gemini 3.1 Pro 2/12). `measure-session.py`
  now prints an estimated **USD** figure; `agy-cost-compare.sh` defaults come from it
  (env still overrides; Gemini rate picked by tier).
- **doctor**: validates each tier→model name still exists in `agy models` (guards against
  agy renaming models across versions).
- **CHANGELOG.md** added.
- **CI** (GitHub Actions): shellcheck + dependency-free test suite + JSON manifest
  validation on every push/PR.

## 0.9.0
- **Background jobs** (`scripts/agy-job.sh`, codex-style): `start`/`list`/`status`/
  `result`/`cancel`, daemonized worker + per-job registry. Slash commands
  `/antigravity:status|result|cancel`. For interactive sessions; headless stays synchronous.

## 0.8.0
- **Code-review fixes**: mktemp+trap for stderr (was a fixed `/tmp` path = concurrency
  race); friendly arg validation; content-anchored `usage()`; `--yolo` passthrough +
  div-by-zero guard in cost-compare; `with open` + scope caveat + multi-match warning in
  measure-session.
- **Slash commands** `/antigravity:delegate|review|setup`; `scripts/doctor.sh`;
  dependency-free `tests/run-tests.sh`.

## 0.7.x
- Repackaged for public release: sanitized internal identifiers, genericized references,
  MIT `LICENSE`, disclaimer.

## 0.4.0–0.6.0
- Deep-research recipe; verification gates incl. agy tamper-detection; cost-discipline
  section (break-even, lean context, digest, cache-TTL trap); `measure-session.py`;
  `docs/AB-RESULTS.md` (measured A/B) and `docs/DEMO-KIT.md`.

## 0.1.0–0.3.0
- Initial plugin: `agy-delegate.sh` wrapper, `antigravity` skill (SDLC model routing,
  conductor/orchestrator), `agy-cost-compare.sh`, marketplace + plugin manifests.
