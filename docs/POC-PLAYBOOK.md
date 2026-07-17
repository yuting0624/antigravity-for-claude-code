# PoC Playbook — measuring hybrid delegation in your org

A step-by-step method for running a **defensible** proof-of-concept of the hybrid
(Claude conducts, agy/Gemini executes) on your own codebase — one that produces numbers
you can put in front of decision-makers. It distills what we learned producing
[`AB-RESULTS.md`](AB-RESULTS.md), including the traps.

> **The one-line thesis:** the cost driver is **`cache_read` × turns** (the conductor
> re-reading context every turn), not output tokens. In our A/B, output barely moved
> (123k → 113k) while `cache_read` halved (10.2M → 5.7M) and turns dropped 126 → 87.
> Optimize *what the conductor never reads*, not *who types the code*.

---

## 0. Principles (read first)

1. **Quality gate first.** A cost number without a fixed quality bar is meaningless —
   and it invites the (correct) criticism that you saved money by verifying less.
2. **One lever at a time.** Apply a lever → remeasure → keep or revert. Every delta must
   be attributable.
3. **Honest break-even.** Below a certain task size the hybrid costs MORE (we measured
   it: a small app was ~1.4M hybrid vs ~1.0M solo). Find your break-even and report it —
   it makes the rest of your numbers credible.
4. **Keep the conductor model FIXED across arms.** Baseline and delegation arms run on
   the **same conductor** (e.g. Opus in both): the "−X% from delegation" claim is only
   attributable — and only immune to *"you just switched to a cheaper model"* — if
   delegation is the sole difference. (Our published A/B kept Opus across all three
   arms for exactly this reason.) This is also delegation's **adoption advantage**:
   nobody has to give up the frontier model — the conductor stays Opus, and the savings
   come from what it no longer reads and re-does. If you ever test a cheaper conductor,
   give it its own clearly-labeled arm; never fold it into the delegation claim.

---

## 1. Fix the quality gate

- Pick **one task type** to start (test generation is ideal: bulky, verifiable,
  low-risk). Expand to migrations / scaffolding / log analysis after the loop works.
- Define a **machine-checkable pass**: the test suite goes green, an eval passes N/N,
  lint + typecheck clean. No "looks good to me".
- The gate is **always run by Claude in a clean state** — never accept the executor's
  self-report (agy has been observed altering its environment to make a check pass; see
  the skill's verification gates).

## 2. Measure the baseline (no delegation)

Run the representative task with solo Claude, pinned session ID, then:

```bash
scripts/measure-session.py <session-id>
```

- **Verify [`prices.json`](../prices.json) against your real Vertex rates first** —
  otherwise the USD figure is fiction.
- Record: turns · output · `cache_read` · COST-WEIGHTED · est. USD · gate result.

## 3. Apply levers, one at a time (ROI order)

| # | Lever | Why it works |
|---|---|---|
| 1 | `--dir <repo>` — agy reads the repo itself | stops pasting context into the conductor |
| 2 | `--digest` — ingest digests, never dumps | the single biggest lever; collapses `cache_read` |
| 3 | Batch: one big delegation over many round-trips | fewer turns = fewer context re-reads |
| 4 | Review the **diff**, not the tree | conductor reads less |
| 5 | Tier down (`flash` where quality holds) | cheaper executor tokens |

(All levers act on the *executor* side or on what the conductor reads — the conductor
model itself stays fixed, per principle 4.)

After each lever: rerun the task → rerun the gate → keep only if quality held.

## 4. Write-task hygiene (the traps, pre-paid)

- **Writes / tool use need `--yolo`.** Headless agy's no-permission behavior has changed
  every few releases (describe-only → scratch-divert → soft-deny on 1.1.3), but in every
  version **the workspace is left untouched while the run still "succeeds."** The one
  durable grant is `--yolo` (`--dangerously-skip-permissions`), on a dedicated branch, with
  `--sandbox`. (`--mode accept-edits` only wrote headless on agy 1.1.0–1.1.2 and is
  soft-denied on 1.1.3 — don't rely on it.) **Always verify with `git status`.** If the
  wrapper returns exit `15`, that's a soft-denied write — add `--yolo`.
- **One shared [`AGENTS.md`](https://github.com/yuting0624/antigravity-for-claude-code#-what-it-does)
  at the repo root** — the biggest first-pass-success factor, which means fewer retries,
  which means fewer conductor turns.
- Long write tasks exceed the ~2-min sync Bash limit → background job (`agy-job`).
- Full symptom-first list: [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md).

## 5. Record per run

| field | note |
|---|---|
| task type / arm / lever set | one lever difference between arms |
| turns · output · `cache_read` | `cache_read` is the leading indicator |
| COST-WEIGHTED · est. USD (Claude side) | from `measure-session.py` |
| Gemini side | **priced separately** — cheap, not free; never merge into the Claude figure |
| gate result | must be equal across arms for the cost claim to stand |

- **n ≥ 3 per arm** for any headline number (we got called out — fairly — for n=1).
- Deliverable: your org's **break-even curve** (task size vs. saving), not a single ratio.

## 6. Rollout & enforcement (organization level)

Measured savings don't survive contact with habit. The pitch that makes adoption easy:
**nobody loses their good model** — developers keep the frontier conductor; the savings
come from delegation. In enforcement-strength order:

1. **Soft layer:** a `CLAUDE.md` line ("bulk work → delegate to agy per the antigravity
   skill; keep the conductor for architecture/hard problems"). Note the plugin already
   injects its cost policy at session start — keep the CLAUDE.md line short to avoid
   duplication.
2. **Recall automation (shipped in the plugin):** the delegate subagent is picked up
   proactively and a prompt-level nudge flags bulk-looking requests. Both are advisory —
   the break-even judgment stays with Claude (full auto-routing measured as a net loss
   below break-even).
3. **Hard enforcement:** per-user/group **spend caps and RBAC via a gateway**
   (e.g. Claude apps gateway on GCP — caps return HTTP 429 at the limit). CLAUDE.md asks;
   gateways enforce. A spend cap also nudges delegation *without* dictating model choice.
4. **Windows fleets:** native Windows headless delegation is not supported upstream
   (hard-hang without a console — antigravity-cli#508). **Require WSL2** for
   participating Windows developers, with the repo on the WSL Linux filesystem
   (`~/...`, never `/mnt/c/...`).

## 7. Report template

> On {task types}, the hybrid cut Claude-side cost **−X%** (COST-WEIGHTED, est. $Y)
> at an **equal quality gate** ({gate}, n={runs}/arm). Break-even: tasks under
> {size} are cheaper solo. Gemini-side cost accounted separately at ${Z}.
> Rates verified against Vertex pricing on {date}.

Always include: the break-even statement, what is *not* counted, and the rate-verification
date. The honest caveats are what make the headline number survive scrutiny.

---

*Companion docs: [`AB-RESULTS.md`](AB-RESULTS.md) (our measured A/B) ·
[`TROUBLESHOOTING.md`](TROUBLESHOOTING.md) (symptom-first fixes) · the `antigravity`
skill's Cost discipline section (the levers, as enforced policy).*
