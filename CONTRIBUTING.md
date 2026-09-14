# Contributing

Thanks for your interest! This is an early-stage, MIT-licensed community project —
issues, PRs, and even a ⭐ all genuinely help shape where it goes.

**Not sure where to start?** Look for the
[`good first issue`](https://github.com/yuting0624/antigravity-for-claude-code/issues?q=is%3Aissue+is%3Aopen+label%3A%22good+first+issue%22)
label.

## What's especially welcome

- **More A/B data points** — repeat the measured runs (n>1) for tighter confidence ([`docs/AB-RESULTS.md`](docs/AB-RESULTS.md)).
- **New SDLC recipes** — when-to-delegate patterns in [`skills/antigravity/SKILL.md`](skills/antigravity/SKILL.md).
- **Support for other CLIs / models** — the delegation wrapper is intentionally thin.
- **Real Vertex prices** — keep [`prices.json`](prices.json) accurate.

## Dev setup

You need the [Antigravity CLI](https://antigravity.google/docs/cli-using) (`agy`,
authenticated — `agy models` should list Gemini models) and Claude Code.

```bash
git clone https://github.com/yuting0624/antigravity-for-claude-code ~/antigravity-for-claude-code
cd ~/antigravity-for-claude-code

# load the plugin live from your working tree ($CLAUDE_PLUGIN_ROOT resolves):
claude --plugin-dir ~/antigravity-for-claude-code
```

The scripts also run standalone — handy for quick iteration:

```bash
scripts/agy-delegate.sh --tier flash "Summarize this in 3 bullets: ..."
```

## Before you open a PR

```bash
bash tests/run-tests.sh          # dependency-free; stubs `agy`, no network
shellcheck scripts/*.sh tests/*.sh   # CI gates on --severity=error
```

- **Tests pass** and shellcheck is clean (CI runs both — see [`.github/workflows/ci.yml`](.github/workflows/ci.yml)). CI runs the suite on Ubuntu **and** on macOS `/bin/bash` 3.2, so a bash-4-ism fails there even if it passed for you on Linux.
- If you touch a manifest, `python3 -c "import json; json.load(open('.claude-plugin/plugin.json'))"` (and `marketplace.json`, `prices.json`) still parse.
- **Keep the skill honest.** [`skills/antigravity/SKILL.md`](skills/antigravity/SKILL.md) is the plugin's brain — if behavior changes, update it. Don't claim a capability the code doesn't have.
- **Cost numbers are estimates.** If you quote figures, say so and point at `prices.json`.
- Add a line to [`CHANGELOG.md`](CHANGELOG.md). There is no "Unreleased" section: a fix goes
  under a new `## x.y.z` heading for the next patch (the maintainer bumps
  `.claude-plugin/plugin.json` and `skills/antigravity/SKILL.md` to match — the suite pins the
  two together); a behaviour change bumps the version in its own PR.
- **CI enforces where that line goes.** #77 filed its entry inside the already-released
  0.27.0, and #82 did it again a fortnight later; neither is a git conflict, because the two
  PRs touch different lines of the same file, so both were found by eye after merging. On
  `pull_request` the suite now compares your `CHANGELOG.md` against the base's and fails if a
  line you *added* sits under a section that has shipped. A line may sit under a heading your
  PR opens, or under the newest heading when its version is ahead of the base's `plugin.json`
  — that second case is what a `release:` PR needs. Locally and on push there is no base, and
  the check reports **skipped** rather than green. Two shapes it refuses on purpose:
  - **A PR stacked on another PR's branch.** Its base already carries the new heading *and*
    the matching `plugin.json`, so neither case applies. Rebasing onto master does not fix it
    by itself once the other PR has merged — open the next `## x.y.z` heading and bump to
    match, which is what the bullet above asks for anyway.
  - **Rewording a section that has already shipped.** That is the same edit as the mistake
    the check exists to catch, and nothing in the diff tells them apart, so it fails and no
    shape of PR makes it pass — a `release:` PR does not, because only the *newest* heading
    is exempt. This is not a required status check: if the edit is deliberate, merge over
    the red line and say so in the PR body.

## Conventions

- Small, focused PRs. Describe *what changed and why*; link the issue.
- Match the surrounding style — POSIX-ish bash, `set -euo pipefail`, quote expansions.
- **Target bash 3.2.** macOS still ships `/bin/bash` 3.2.57 (GPLv3 is why), and macOS is a
  supported platform, so `declare -A`, `readarray`/`mapfile`, `${var^^}` and friends are out.
  Same for GNU-only flags on `sed`, `date` and `grep` — BSD userland is the floor. Testing on
  Linux only will not catch these; CI's macOS job does, but run the suite on 3.2 locally when
  you can.
- New scripts get a `usage()` and a test in `tests/run-tests.sh`.

## Reporting bugs / ideas

Open an issue with what you ran (`agy --version`, the command, OS) and what you
expected vs. saw. Feature ideas welcome too — even half-formed ones.

By contributing you agree your work is licensed under the project's [MIT License](LICENSE).
