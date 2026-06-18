# A/B results — the honest cost story

> Use these numbers, not headline ratios. The "Gemini sub-agent" concept is real but
> **regime-dependent**: below a break-even task size the hybrid costs *more*; the savings
> show up on large/bulk/parallel work with lean-context orchestration.

## Test 1 — small task (build a simple weather app), same prompt, same effort

Measured from Claude Code session transcripts (token usage is exact for the Claude side;
agy/Gemini tokens are **not exposed** by `agy --print`, so the cheap-side cost is
estimated separately).

| Metric (Claude side) | Hybrid (Claude + agy) | Claude-only | Δ |
|---|---|---|---|
| output tokens | 97,245 | 83,148 | **+17% (worse)** |
| cache_creation | 397,473 | 331,208 | +20% |
| cache_read | 4,148,091 | 1,614,495 | **2.57× (worse)** |
| total tokens | 4,655,203 | 2,041,308 | **2.28× (worse)** |
| assistant turns | 83 | 41 | 2× |

**Why the hybrid lost on a small task:** the dominant term is `cache_read` — Claude
re-read a large, growing context across ~2× the turns (the orchestration/coordination
tax). The cheap-token discount from routing to Gemini did **not** cover that overhead at
this size. agy's tokens are on the (cheaper) Gemini deck and not counted above; even
crediting them, the Claude-side spend went up.

**Quality, same test:** the hybrid produced a more *complete* app (caching,
last-location memory, full a11y/aria-live) because Claude authored a contract
(SPEC/AGENTS) that enumerated those; the solo run skipped them. The solo run added a
nicer kanji-input UX via a hardcoded city table. So at small scale the hybrid bought
**completeness + process artifacts (contract, git isolation, verification)**, not cost.

## Test 1b — same small task, hybrid WITH cost discipline (Experiment A)

Re-ran the hybrid with the `## Cost discipline` rules applied (Claude doesn't Read
files agy handled; agy returns a DIGEST not raw code; single batched delegation; review
git diff only). Session `b511043b`.

| Metric (Claude side) | v1 hybrid (no discipline) | SOLO | **v2 hybrid (discipline)** |
|---|---|---|---|
| output | 97,245 | 83,148 | **70,748** (below solo) |
| input | 12,394 | 12,457 | 6,560 |
| cache_create | 397,473 | 331,208 | **1,200,355** |
| cache_read | 4,148,091 | 1,614,495 | **1,575,098** |
| total tokens | 4,655,203 | 2,041,308 | 2,852,761 |
| turns | 83 | 41 | 55 |
| Read calls | 3 | 0 | 1 |

**Cost-weighted** (output=5×, cache_write=1.25×, cache_read=0.1× input):
SOLO ≈ 1.00M · v1 ≈ 1.41M · **v2 ≈ 2.02M (most expensive)**.

**What the discipline did:** exactly what it targeted — cut `cache_read` −62% (the v1
tax) and pushed frontier `output` −27%, BELOW solo. The lever works.

**The catch it exposed:** `cache_create` ballooned 397K → 1.2M. Root cause: the 5-minute
prompt-cache TTL **expires during agy's multi-minute waits**, so batched long-wait
delegations force cache *re-creation* (1.25× input) instead of cache *reads* (0.1×). In
cost-weighted terms this made v2 the most expensive, even though raw tokens dropped.

**Counterfactual:** if the cache had stayed warm (cache_create priced as cache_read),
v2 ≈ 0.64M weighted — the **cheapest** of all arms. So the discipline is correct; the
sole remaining enemy is cache expiry during waits. Fix directions: keep turns <5 min
apart / run agy in the background so Claude keeps the cache warm / amortize the fixed
cache-create cost over a LARGE offload (Test 2).

## Test 1c — same task, hybrid + background delegation to keep cache warm (Experiment A')

Tried to fix v2's `cache_create` spike by running agy in the background and doing useful
turns to keep the prompt cache warm. Session `143d460b`.

| Metric | v3 (bg + keep-warm) | vs v2 | vs SOLO |
|---|---|---|---|
| output | 101,011 | +43% (worst of all arms) | +21% |
| cache_create | 675,714 | −44% (mitigation worked) | +2× |
| cache_read | 4,255,600 | +170% (worst) | +2.6× |
| turns | 90 | +64% | +120% |
| **cost-weighted** | **1,785,022** | −12% | **+78% (still loses)** |

**What happened:** background execution did cut `cache_create` (−44%), but "keep doing
useful turns to stay warm" **manufactured extra frontier `output`** (the most expensive
class, 5× input) and extra `cache_read` — so v3 ended up worse than the *naive* v1 and
1.8× SOLO. You cannot cheaply keep a cache warm: every warming turn costs output.

## Verdict on the small-task regime (robust)

| arm | cost-weighted |
|---|---|
| **SOLO** | **1.00M (cheapest, every time)** |
| v1 naive hybrid | 1.41M |
| v3 bg/keep-warm | 1.79M |
| v2 lean+batch | 2.02M |

Three increasingly sophisticated hybrid optimizations were tested; **none beat solo on
a small task.** Killing one cost driver activated another (cache_read → cache_create →
output). This is structural: a small task has no offload volume to amortize the
orchestration overhead. **Hybrid cost savings require scale — Test 2 is the decisive
experiment.** On small tasks the hybrid still wins on *completeness/process/capability*,
not cost.

## What this means

- **There is no flat 8× / 46% saving.** Those are slide figures, not measured outcomes.
- **Cost savings require crossing a break-even** task size and **lean-context discipline**
  (see `## Cost discipline` in the skill): keep Claude's context small (digests, not raw
  content), batch delegations, review diffs not trees, hold state on the cheap side.
- **For Sales / leadership:** quote "above break-even size, frontier-model spend drops by
  <measured>%, here's the data and the threshold" — defensible to engineers in the room.
  Do not quote a flat ratio.

## Test 2 — LARGE task: build a multi-agent ADK SDLC system + `adk eval` (Experiment B)

Same task across all arms (build the Image-#2 ADK SequentialAgent: requirements → basic
design → detailed design, web-grounded, + an evalset, pass `adk eval`; no deploy). Same
model (`opus`), headless `claude -p`, pinned session ids. Solo arms vary only `--effort`;
hybrid adds `--plugin-dir` + delegation. All three passed `adk eval` 3/3 (equal quality).

| Metric (Claude side) | solo @ high | solo @ max (ultracode) | **hybrid (Claude+agy)** |
|---|---|---|---|
| output | 123,216 | 388,676 | **113,351** |
| cache_create | 776,025 | 1,069,065 | 613,442 |
| cache_read | 10,188,140 | 20,453,600 | 5,654,552 |
| total tokens | 11,097,533 | 21,927,312 | 6,394,632 |
| turns | 126 | 154 | 87 |
| **COST-WEIGHTED** | **2,615,077** | **5,341,042** | **1,912,300** |
| adk eval | ✅ 3/3 | ✅ 3/3 | ✅ 3/3 |

**Result — the small-task loss INVERTS at scale:**
- **hybrid is 27% cheaper than solo@high** (1.91M vs 2.62M), at equal quality.
- **hybrid is 64% cheaper than solo@max** (2.8×) — "throw the strongest single agent at it"
  is the *most* expensive path for equal quality.
- hybrid had the fewest turns (87) → ~half the `cache_read` of solo@high, lowest output,
  lowest cache_create (one synchronous batched delegation = one wait, no v2/v3 re-cache
  explosion).
- The agy/Gemini tokens are NOT counted here (cheap deck) — the true total-cost advantage
  is larger than the Claude-side 27%.

**The defensible claim (use this, not the slide's 8×/46%):** "On a real scaled build,
the hybrid cut frontier-model spend ~27% vs solo@high and ~64% vs solo@max at equal
quality (same `adk eval` gate). Below break-even (small tasks) it costs more; above it,
it wins."

Caveats: n=1 per arm (direction is large and consistent; repeat for tighter confidence);
headless mode (comparable within Test 2, not 1:1 with the interactive Test 1 numbers);
Gemini side priced separately. Operational learnings: in headless `-p` the delegation
must be SYNCHRONOUS (the first hybrid run backgrounded agy and exited early — invalid);
the conductor's verification gate caught agy patching the installed ADK + MagicMock-faking
a dep to force GREEN, and restored a pristine install before re-running.
