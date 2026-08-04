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

1. **Pick the regime before you measure anything.** One question decides whether a cost
   PoC is worth running at all:

   > **Does the conductor have to keep the raw material in its context to be accountable
   > for the result?**

   If **yes** — editing a repo, fixing a bug, anything where Claude must verify the code
   it is responsible for — **expect parity at best, and do not build a cost story on it.**
   Delegation cannot remove work the conductor has to re-derive, and it will not: measured,
   Claude re-reads handed-over context rather than trusting it, which is the same rule that
   makes the hybrid safe ([§4](#4-write-task-hygiene-the-traps-pre-paid) — agy has been
   observed patching its own environment to force a green test). You cannot have "the
   conductor doesn't re-read" and "the conductor owns correctness" at once.

   If **no** — the digest *is* the deliverable: research, log analysis, multi-source lookup,
   audio/video — the material never has to come back, and this is where the saving lives.
   Measured: a 62k-token corpus offloaded to a digest leaves the conductor carrying **4.4k
   instead of 62k**, i.e. **$0.002 vs $0.031 per subsequent turn** — $0.53 vs $2.05 across
   50 turns.

   Two independent efforts (ours on Harbor, a colleague's on SWE-bench and SWE-bench Pro)
   spent days on the first regime and landed within ~10% of solo. Ask the question first.

2. **Quality gate first.** A cost number without a fixed quality bar is meaningless —
   and it invites the (correct) criticism that you saved money by verifying less.
3. **One lever at a time.** Apply a lever → remeasure → keep or revert. Every delta must
   be attributable.
4. **Honest break-even.** Below a certain task size the hybrid costs MORE (we measured
   it: a small app was ~1.4M hybrid vs ~1.0M solo). Find your break-even and report it —
   it makes the rest of your numbers credible.
5. **Keep the conductor model FIXED across arms.** Baseline and delegation arms run on
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
model itself stays fixed, per principle 5.)

After each lever: rerun the task → rerun the gate → keep only if quality held.

## 4. Write-task hygiene (the traps, pre-paid)

- **Two write grants, and the narrow one is not `--yolo`.** Headless agy's
  no-permission behavior has shifted every few releases (describe-only pre-1.1.0 ·
  scratch-divert 1.1.0–1.1.2 · soft-deny 1.1.3+), and in every version an ungranted write
  leaves **your workspace untouched while the run still "succeeds"**
  ([#10](https://github.com/yuting0624/antigravity-for-claude-code/issues/10)). Two things
  grant it:
  
  - **`permissions.allow` in `~/.gemini/antigravity-cli/settings.json`** — a
    `write_file(<dir>)` entry allows writes **recursively beneath `<dir>`** and needs no
    flag. This is the narrower grant and usually the right one.
  - **`--yolo`** (`--dangerously-skip-permissions`) — auto-approves **all** tools, not just
    writes. Needed when no rule covers the target, and for web / Vertex AI Search / terminal
    tools.
  
  Confirmed on **agy 1.1.9** by a controlled A/B ([#37](https://github.com/yuting0624/antigravity-for-claude-code/issues/37)):
  a covered target wrote with no flag; an uncovered one came back `PERMISSION_DENIED` with
  the rule as the only variable. agy's own denial text names the rule and offers `--yolo` as
  the alternative. Not verified on other versions, and a glob form (`write_file(/path/**)`)
  was reported *not* to match. Either way: run write tasks on a branch and verify with
  `git status`; the wrapper maps a soft-deny to exit `15`.
- **One shared [`AGENTS.md`](https://github.com/yuting0624/antigravity-for-claude-code#-what-it-does)
  at the repo root** — the biggest first-pass-success factor, which means fewer retries,
  which means fewer conductor turns.
- Long write tasks exceed the ~2-min sync Bash limit → background job (`agy-job`).
- Full symptom-first list: [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md).

## 5. Record per run

### Conditions — requirements, not advice

Every one of these cost us a rerun. Getting any of them wrong does not add noise; it
produces a **confident wrong number**.

| condition | why |
|---|---|
| **every trial cold** — 1 trial = 1 job, ≥5 min between | the prompt cache TTL is 5 min. On short tasks the *cache draw* is bigger than the arm difference: our "+46%" headline became "indistinguishable" once we forced cold, because one arm had happened to draw 2 warm starts and the other 1 |
| **identical wall-clock and budget caps on both arms** | a cap on one arm is a second variable |
| **executor usage to a file, not stderr** | set `AGY_USAGE_LOG=/path` (plugin ≥ 0.22.0). A conductor keeping its context lean writes `2>&1 \| tail -N`, and the usage line is precisely what `tail` drops — we lost most of a run's executor data that way |
| **delegation count per trial** | a trial with **0 delegations is the baseline arm wearing a hat**. Measured: the plugin merely installed delegated 0 times in 122 turns, and 0 times in 6 trials even with break-even guidance injected every turn. Verify it happened before believing any delta |
| **n ≥ 3 per arm, and report ranges** | we were called out — fairly — for n=1. Report per-trial ranges, not just means: ours spanned 1.7–3.1× within an arm, which swallows most differences you would want to claim |

### Metric: cost per *correct* result, not cost per trial

Use **cost-of-pass** — total spend ÷ number of trials that passed the gate.

Cost per trial is gameable by failing cheaply, and it got us: our cheapest hybrid trial was
the one that hit the wall-clock cap and failed. Including it made the arm look 14.7% worse
than baseline; excluding it, 42.1%. Neither number is wrong — the *metric* was.

### Fields

| field | note |
|---|---|
| task type / arm / lever set | one lever difference between arms |
| gate result (pass/fail) | the denominator of cost-of-pass; must be machine-checkable |
| delegations this trial | 0 means you measured the baseline twice |
| turns · output · `cache_read` | conductor `cache_read` is the leading indicator — it *is* the carry |
| Claude-side USD | `measure-session.py` (**Claude side only** — see below) |
| agy-side USD | priced **separately**; cheap is not free |
| wall-clock | delegation costs latency even when it saves tokens |

### The two accounting systems are not the same shape

Merging them is the easiest way to be badly wrong, in either direction:

| | Claude / Harbor | agy / Gemini |
|---|---|---|
| total | `n_input = input + cache_creation + cache_read` | `total = input + output` (`thinking` is inside `output`) |
| cached reads | `n_cache_tokens = cache_read`, an **inner subset** of the input total | `cache_read` is a **separate counter** — not in `total`, not a subset of `input` |

Price the agy side as three separate terms (`input×in + output×out + cache_read×cached`).
Assert `input + output == total` every run and stop if it breaks rather than reinterpreting
it — we got this backwards once and mispriced the whole executor side.

- Deliverable: your org's **break-even curve** (task size vs. saving), not a single ratio.
  Ours came out at roughly **5.7 delegations** against one corpus — past that, each `agy`
  call is an independent session that re-ingests from scratch and the saving inverts.

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

> On {task types}, the hybrid cut cost-of-pass **−X%** ({$/passing trial}, n={runs}/arm,
> {delegations}/trial) at an **equal quality gate** ({gate}). Break-even: tasks under
> {size}, or more than {N} delegations against the same material, are cheaper solo.
> Claude side ${A}, agy side ${B}, accounted separately.
> Conductor {model}, executor {model}, agy {version}, measured {date};
> rates verified against Vertex pricing on {date}.

Always include: the break-even statement, what is *not* counted, the model/version
triple, and the rate-verification date. The honest caveats are what make the
headline number survive scrutiny — and the version triple is what stops the number being
quoted, a year later, as if it were a property of the plugin.

## 8. When the answer is parity

**This is the likely outcome on coding tasks, and it is a result, not a failed PoC.** Two
independent efforts landed within ~10% of solo before either of them asked the regime
question in §0. Report it and move the conversation, rather than re-running until a number
appears — a stakeholder can reproduce parity in an afternoon, and a claim they can break is
worse than no claim.

What to present instead, in descending order of how hard it is to argue with:

1. **Work the frontier model cannot do at all.** Audio and video understanding
   (`/antigravity:media`), Vertex AI Search over internal data, grounded search. There is no
   cost comparison because there is no baseline — the task either happens or it doesn't.
2. **The context ceiling.** On material that would otherwise exceed the conductor's window,
   offloading is the difference between finishing and not. That is not a percentage, and it
   is the thing that actually blocks people.
3. **Recall, via two independent scans.** A second model *reviewing* the first cannot raise
   recall — it only ever sees what was already reported. Two models *scanning* independently
   can, and the union beats either alone in both directions. If you want a quality story
   rather than a cost story, this is the one with a mechanism behind it.
4. **Wall-clock**, if you fan out. Note it moves the *opposite* way for a single delegation:
   ours added roughly 1.3–1.9× latency.

And say plainly what you measured and did not find. The parity result is what makes the
other four credible.

---

*Companion docs: [`AB-RESULTS.md`](AB-RESULTS.md) (our measured A/B) ·
[`TROUBLESHOOTING.md`](TROUBLESHOOTING.md) (symptom-first fixes) · the `antigravity`
skill's Cost discipline section (the levers, as enforced policy).*
