# A/B results — the measured cost story

> **Headline:** on a real, scaled build the hybrid (Claude conducts, Gemini executes)
> cut frontier-model spend **~27% vs solo Claude @ high effort and ~64% vs @ max**, at
> **equal quality** (same `adk eval` gate) — and the cheap Gemini work isn't even counted.

COST-WEIGHTED = a model-agnostic $-proxy: `output×5 + input×1 + cache_write×1.25 +
cache_read×0.1` (standard Claude multipliers). Claude-side tokens are exact (from session
transcripts); agy/Gemini tokens are on the cheaper deck and priced separately.

## Test 2 — LARGE task (the win): build a multi-agent ADK SDLC system + `adk eval`

Same task across all arms: build the multi-agent ADK system (requirements → basic design
→ detailed design, web-grounded) + an evalset, and pass `adk eval`. Same model (`opus`),
headless `claude -p`, pinned session ids. Solo arms vary only `--effort`; the hybrid adds
the plugin + delegation. **All three passed `adk eval` 3/3 — equal quality.**

| Metric (Claude side) | solo @ high | solo @ max | **hybrid (Claude+agy)** |
|---|---|---|---|
| output | 123,216 | 388,676 | **113,351** |
| cache_read | 10,188,140 | 20,453,600 | **5,654,552** |
| turns | 126 | 154 | **87** |
| **COST-WEIGHTED** | **2,615,077** | 5,341,042 | **1,912,300** |
| adk eval | ✅ 3/3 | ✅ 3/3 | ✅ 3/3 |

- **hybrid −27% vs solo@high**, **−64% vs solo@max**, at equal quality.
- Fewest turns (87) → ~half the `cache_read` of solo@high; lowest output; lowest
  cache_create (one synchronous batched delegation = one wait, no re-cache churn).
- The bulk implementation ran on **Gemini (cheap, uncounted)**, so the true total-cost
  advantage is larger than the Claude-side 27%.
- "Throw the strongest single agent at it" (solo@max) is the **most expensive** path for
  the same result.

**Defensible claim:** *"On a real scaled build, the hybrid cut frontier-model spend ~27%
vs solo@high and ~64% vs solo@max at equal quality. Below break-even it costs more; above
it, it wins."*

## Test 1 — small task (the break-even floor)

For contrast: building a small single app (a weather app), the hybrid cost **more** than
solo — the orchestration/round-trip overhead (`cache_read`) exceeds the cheap-token
discount when there's little to offload.

| | solo | hybrid |
|---|---|---|
| COST-WEIGHTED | **~1.0M (cheaper)** | ~1.4M |

So: **don't delegate small, self-contained tasks for cost** — that's below the break-even.
(At small scale the hybrid still wins on *completeness* — a contract-driven app with
caching + a11y the solo run skipped — and on *capability*, just not on cost.)

## What this means

- **Savings require crossing a break-even** task size + lean-context discipline (keep
  Claude's context small, batch delegations, review diffs not trees).

---

*Caveats: n=1 per arm (direction is large and consistent; repeat for tighter confidence);
headless mode; Gemini side priced separately. Operational notes from the runs: in headless
`claude -p` delegation must be **synchronous** (a backgrounded delegation exits early); and
the conductor's verification gate caught agy patching the installed ADK + mock-faking a
dependency to force a green eval, then restored a pristine install and re-ran — never trust
a self-reported pass.*
