"""Post-run scoring: restore the hidden tests, build/vet/test, diff stats, write
attribution, and the two accounting decks — assembled into one run.json.

Nothing here talks to a model. Everything is derived from files the run left behind:
the worktree, raw/result.json, raw/transcripts/*.jsonl, raw/agy_usage.log,
raw/tool_trace.jsonl, raw/meta.json, and agy's brain transcripts on this machine.
"""
from __future__ import annotations

import glob
import json
import os
import re
from typing import Dict, List, Optional, Tuple

import agy_usage
import claude_usage
from common import (AGY_HEADS, Prices, classify_path, read_json, read_text, run, sha256_file,
                    sha256_text, write_json)

BRAIN_DIR = os.path.expanduser(os.environ.get("AGY_BRAIN_DIR", "~/.gemini/antigravity-cli/brain"))
WEB_TOOL_NAMES = {"read_url_content", "search_web", "web_search", "browser_subagent",
                  "open_browser_url", "read_browser_page", "google_search"}
AGY_WRITE_TOOLS = {"write_to_file", "replace_file_content", "multi_replace_file_content"}
KNOWN_STEP_TYPES = {"RUN_COMMAND", "CODE_ACTION", "VIEW_FILE", "LIST_DIRECTORY", "PLANNER_RESPONSE",
                    "USER_INPUT", "GENERIC", "CHECKPOINT", "SYSTEM_MESSAGE", "ERROR_MESSAGE"}


# ------------------------------------------------------------ go toolchain --

def go_env(repo: dict, gomod_dir: str, gobuild_dir: str) -> Dict[str, str]:
    # TMPDIR: macOS's default temp dir sits behind the /var -> /private/var symlink, and
    # tests that compare a resolved path with t.TempDir() fail there for no reason of the
    # code's (measured: zoekt's TestSyncIndexesWithRootRelativeName). A plain directory
    # under the bench home removes that class of environment failure for every arm alike.
    # -mod=readonly: with -mod=mod a plain `go doc`/`go list` rewrites go.mod/go.sum from the
    # module cache (measured: a `go doc` call showed up as a tree change in a hybrid-forced
    # run); readonly makes any such need a loud failure instead of a silent edit.
    tmp = os.path.join(os.path.dirname(gomod_dir), "tmp")
    os.makedirs(tmp, exist_ok=True)
    env = {"GOMODCACHE": gomod_dir, "GOCACHE": gobuild_dir, "GOPROXY": "off", "GOTOOLCHAIN": "local",
           "GOSUMDB": "off", "GOWORK": "off", "GOFLAGS": "-mod=readonly", "CGO_ENABLED": "0", "TMPDIR": tmp}
    env.update(repo.get("go_env") or {})
    return env


def list_packages(repo_dir: str, env: Dict[str, str], exclude_regex: Optional[str], timeout: int = 300) -> List[str]:
    r = run(["go", "list", "./..."], cwd=repo_dir, env=env, timeout=timeout)
    pkgs = [p.strip() for p in r.out.splitlines() if p.strip()]
    if exclude_regex:
        rx = re.compile(exclude_regex)
        pkgs = [p for p in pkgs if not rx.search(p)]
    return pkgs


def parse_go_test_json(out: str) -> dict:
    """Aggregate `go test -json` events: failed tests by package, package outcomes."""
    failed_tests: List[str] = []
    passed_tests = 0
    pkg_status: Dict[str, str] = {}
    build_failed: List[str] = []
    for line in out.splitlines():
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            ev = json.loads(line)
        except Exception:  # noqa: BLE001
            continue
        act = ev.get("Action")
        pkg = ev.get("Package") or ""
        test = ev.get("Test")
        if test:
            if act == "fail":
                failed_tests.append("%s.%s" % (pkg, test))
            elif act == "pass":
                passed_tests += 1
        else:
            if act in ("pass", "fail", "skip"):
                pkg_status[pkg] = act
            if act == "output" and "[build failed]" in str(ev.get("Output", "")):
                build_failed.append(pkg)
    failed_pkgs = sorted(p for p, s in pkg_status.items() if s == "fail")
    return {"failed_tests": failed_tests, "passed_tests": passed_tests,
            "failed_packages": failed_pkgs, "build_failed_packages": sorted(set(build_failed)),
            "packages": len(pkg_status)}


def run_tests(repo_dir: str, env: Dict[str, str], pkgs: List[str], run_regex: Optional[str],
              extra_args: List[str], timeout: int, parallel_p: Optional[int] = None) -> Tuple[dict, "run.Result"]:
    cmd = ["go", "test", "-count=1", "-json"]
    if parallel_p:
        cmd += ["-p", str(parallel_p)]
    if run_regex:
        cmd += ["-run", run_regex]
    cmd += list(extra_args or [])
    cmd += pkgs
    r = run(cmd, cwd=repo_dir, env=env, timeout=timeout)
    parsed = parse_go_test_json(r.out)
    parsed["rc"] = r.rc
    parsed["timed_out"] = r.timed_out
    parsed["seconds"] = round(r.seconds, 1)
    parsed["pass"] = (r.rc == 0 and not r.timed_out and not parsed["failed_tests"] and not parsed["failed_packages"])
    parsed["stderr_tail"] = r.err[-2000:]
    return parsed, r


# ------------------------------------------------------------------ diffs ---

def diff_stats(patch_text: str, author_code_files: List[str]) -> dict:
    files: Dict[str, dict] = {}
    cur: Optional[str] = None
    binary: List[str] = []
    for line in patch_text.splitlines():
        if line.startswith("diff --git "):
            m = re.match(r"diff --git a/(.*?) b/(.*)$", line)
            cur = m.group(2) if m else line[11:]
            files[cur] = {"added": 0, "removed": 0, "class": classify_path(cur)}
        elif cur is None:
            continue
        elif line.startswith("Binary files") or line.startswith("GIT binary patch"):
            binary.append(cur)
        elif line.startswith("+++") or line.startswith("---"):
            continue
        elif line.startswith("+"):
            files[cur]["added"] += 1
        elif line.startswith("-"):
            files[cur]["removed"] += 1
    agg = {"files_touched": len(files), "code_added": 0, "code_removed": 0, "test_added": 0, "test_removed": 0,
           "doc_added": 0, "other_added": 0, "gomod_changed": False, "files": files,
           "files_outside_author_set": [], "stray_binaries": binary,
           "patch_sha256": sha256_text(patch_text)}
    author_set = set(author_code_files or [])
    for path, f in files.items():
        c = f["class"]
        if c == "code":
            agg["code_added"] += f["added"]; agg["code_removed"] += f["removed"]
            if path not in author_set:
                agg["files_outside_author_set"].append(path)
        elif c == "test":
            agg["test_added"] += f["added"]; agg["test_removed"] += f["removed"]
        elif c == "doc":
            agg["doc_added"] += f["added"]
        elif c == "gomod":
            agg["gomod_changed"] = True
        else:
            agg["other_added"] += f["added"]
    agg["files_outside_author_set"].sort()
    return agg


# ---------------------------------------------------------- attribution -----

GOMOD_NAMES = ("go.mod", "go.sum")


def _changed_paths(pre: dict, post: dict) -> Optional[List[str]]:
    """Paths whose (name, hash) differ between two tree events; None if a side lacks the list."""
    a, b = pre.get("files"), post.get("files")
    if a is None or b is None:
        return None
    da = {f[0]: f[1] for f in a}
    db = {f[0]: f[1] for f in b}
    return sorted(set(k for k in set(da) | set(db) if da.get(k) != db.get(k)))


def attribute_writes(trace_path: str, agy_background: bool = False) -> dict:
    """Pair pre/post tree fingerprints per tool call; attribute each change.

    claude_tool: Edit/Write/MultiEdit/NotebookEdit; agy: a Bash call whose head is the
    wrapper; toolchain_gomod: a `go` command whose only changes are go.mod/go.sum (the
    module tooling, not the agent); claude_bash: any other Bash change — the one that must
    be zero in hybrid-forced. File lists come from the hook when it recorded them.
    """
    out = {"claude_tool": 0, "claude_bash": 0, "agy": 0, "agy_background": 0, "toolchain_gomod": 0, "between_calls": 0,
           "post_missing": 0, "events": 0, "gate_blocks": 0, "blocked_heads": {}, "gate_allows": 0, "pairing": "tool_use_id",
           "claude_bash_commands": [], "claude_bash_files": [], "agy_files": [], "claude_tool_files": []}
    if not os.path.isfile(trace_path):
        out["pairing"] = "no_trace"
        return out
    events: List[dict] = []
    with open(trace_path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            try:
                events.append(json.loads(line))
            except Exception:  # noqa: BLE001
                continue
    out["events"] = len(events)
    gate_cmds: Dict[str, str] = {}
    gate_heads: Dict[str, List[str]] = {}
    gate_blocked: set = set()
    for ev in events:
        if ev.get("event") == "gate":
            if ev.get("decision") == "block":
                out["gate_blocks"] += 1
                h = (ev.get("heads") or ["?"])[0] if ev.get("heads") else (str(ev.get("command", "")).split() or ["?"])[0]
                out["blocked_heads"][h] = out["blocked_heads"].get(h, 0) + 1
            else:
                out["gate_allows"] += 1
            if ev.get("tool_use_id"):
                gate_cmds[ev["tool_use_id"]] = str(ev.get("command", ""))
                gate_heads[ev["tool_use_id"]] = [str(h) for h in (ev.get("heads") or [])]
                if ev.get("decision") == "block":
                    gate_blocked.add(ev["tool_use_id"])
    tree = [ev for ev in events if ev.get("event") in ("PreToolUse", "PostToolUse")]
    have_ids = all(ev.get("tool_use_id") for ev in tree) and bool(tree)
    if not have_ids:
        out["pairing"] = "sequence"

    def _base(head: str) -> str:
        b = os.path.basename(str(head or ""))
        return b[:-3] if b.endswith(".sh") else b

    def classify(pre: dict, post: dict) -> None:
        """Attribute the change between two tree events to the call `pre` opened."""
        tool = str(post.get("tool_name") or pre.get("tool_name") or "")
        head = str(post.get("head") or pre.get("head") or "")
        base = _base(head)
        tid = pre.get("tool_use_id") or post.get("tool_use_id")
        heads = [_base(h) for h in gate_heads.get(tid, [])]
        changed = _changed_paths(pre, post)
        if tool == "Bash":
            if base in AGY_HEADS or any(h in AGY_HEADS for h in heads):
                # the wrapper may not be the first word: `printf '%s\n' … | agy-delegate …`
                # (measured in the hand-off arm) pipes the task text in; the gate records every
                # segment's head, so the pipeline is the wrapper's call
                out["agy"] += 1
                if changed:
                    out["agy_files"].extend(p for p in changed if p not in out["agy_files"])
            elif base == "go" and changed is not None and changed and all(os.path.basename(p) in GOMOD_NAMES for p in changed):
                out["toolchain_gomod"] += 1
            elif agy_background and base not in ("go", "gofmt", "git"):
                # a delegation was backgrounded (measured: `sleep 600; tail …output` polling a
                # background agy-delegate while it edited pkg/cmd/issue/edit/edit.go); the
                # read-only poll cannot write, the wrapper running underneath can
                out["agy_background"] += 1
                if changed:
                    out["agy_files"].extend(p for p in changed if p not in out["agy_files"])
            else:
                out["claude_bash"] += 1
                out["claude_bash_commands"].append(gate_cmds.get(tid, head)[:200])
                if changed:
                    out["claude_bash_files"].extend(p for p in changed if p not in out["claude_bash_files"])
        else:
            out["claude_tool"] += 1
            if changed:
                out["claude_tool_files"].extend(p for p in changed if p not in out["claude_tool_files"])

    pending: Dict[str, dict] = {}
    seq: List[dict] = []
    last_fp: Optional[str] = None    # the most recent fingerprint from either hook
    open_pre: Optional[dict] = None  # the latest PreToolUse whose PostToolUse has not arrived
    for ev in tree:
        if ev["event"] == "PreToolUse":
            if last_fp is not None and ev.get("fp") and ev["fp"] != last_fp:
                if open_pre is not None and open_pre.get("tool_use_id") not in gate_blocked:
                    # the previous call ran but its PostToolUse never fired — Claude Code skips
                    # the hook when the tool result is an error (measured: a 20-minute
                    # agy-delegate that exited non-zero after writing five files) — so the
                    # change first shows up here and belongs to that call, not to the gap
                    out["post_missing"] += 1
                    classify(open_pre, ev)
                else:
                    out["between_calls"] += 1
            last_fp = ev.get("fp") or last_fp
            open_pre = ev
            if have_ids:
                pending[ev["tool_use_id"]] = ev
            else:
                seq.append(ev)
            continue
        pre = None
        if have_ids:
            pre = pending.pop(ev.get("tool_use_id"), None)
        else:
            for i in range(len(seq) - 1, -1, -1):
                if seq[i].get("tool_name") == ev.get("tool_name"):
                    pre = seq.pop(i)
                    break
        if pre is not None and pre is open_pre:
            open_pre = None
        last_fp = ev.get("fp") or last_fp
        if pre is None or not pre.get("fp") or not ev.get("fp") or pre["fp"] == ev["fp"]:
            continue
        classify(pre, ev)
    return out


# ---------------------------------------------------- suite failure triage ----

def touched_import_paths(repo_dir: str, env: Dict[str, str], changed_paths: List[str]) -> List[str]:
    """Import paths of the packages whose non-test .go files the agent changed."""
    mod = run(["go", "list", "-m"], cwd=repo_dir, env=env, timeout=120).out.strip().splitlines()
    mod = mod[0] if mod else ""
    out: List[str] = []
    for path in changed_paths:
        if classify_path(path) != "code":
            continue
        d = os.path.dirname(path)
        ip = (mod + "/" + d) if d else mod
        if ip and ip not in out:
            out.append(ip)
    return out


def unrelated_failed_packages(repo_dir: str, env: Dict[str, str], failed_pkgs: List[str], touched: List[str]) -> Tuple[List[str], List[str]]:
    """Split failed packages into (unrelated, related): a package is unrelated when none of
    its transitive dependencies is a package the agent changed, so its failure cannot be a
    regression from the change (measured: k6's websockets package, which hung twice under
    two-lane load, imports nothing the k6 task touches)."""
    unrelated: List[str] = []
    related: List[str] = []
    for pkg in failed_pkgs:
        deps = set(run(["go", "list", "-deps", pkg], cwd=repo_dir, env=env, timeout=600).out.split())
        if pkg in touched or any(t in deps for t in touched):
            related.append(pkg)
        else:
            unrelated.append(pkg)
    return unrelated, related


# -------------------------------------------------------- brain transcripts --

def audit_brain(cid: str) -> dict:
    path = os.path.join(BRAIN_DIR, cid, ".system_generated", "logs", "transcript.jsonl")
    a = {"present": os.path.isfile(path), "steps": {}, "tool_calls": {}, "failed_commands": 0,
         "web_steps": 0, "write_steps": 0, "unknown_step_types": [], "first_step_at": None, "last_step_at": None}
    if not a["present"]:
        return a
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            try:
                st = json.loads(line)
            except Exception:  # noqa: BLE001
                continue
            t = str(st.get("type") or "?")
            a["steps"][t] = a["steps"].get(t, 0) + 1
            if t not in KNOWN_STEP_TYPES and t not in a["unknown_step_types"]:
                a["unknown_step_types"].append(t)
            ec = st.get("exit_code")
            if isinstance(ec, int) and ec != 0:
                a["failed_commands"] += 1
            ca = st.get("created_at")
            if ca:
                a["first_step_at"] = a["first_step_at"] or ca
                a["last_step_at"] = ca
            for tc in st.get("tool_calls") or []:
                name = str((tc or {}).get("name") or "?")
                a["tool_calls"][name] = a["tool_calls"].get(name, 0) + 1
                low = name.lower()
                if name in WEB_TOOL_NAMES or "url" in low or "browser" in low or low.startswith("web_") or low.endswith("_web"):
                    a["web_steps"] += 1
                if name in AGY_WRITE_TOOLS:
                    a["write_steps"] += 1
    return a


# ------------------------------------------------------------------ main -----

def score_run(run_dir: str, repo_dir: str, task: dict, task_dir: str, repo_cfg: dict, arm: str,
              prices: Prices, gomod_dir: str, gobuild_dir: str, meta: Optional[dict] = None) -> dict:
    raw = os.path.join(run_dir, "raw")
    meta = meta or (read_json(os.path.join(raw, "meta.json")) if os.path.isfile(os.path.join(raw, "meta.json")) else {})
    env = go_env(repo_cfg, gomod_dir, gobuild_dir)
    hidden_files = list(task["hidden_tests"]["files"])
    notes: List[str] = []

    # 1. snapshot the patch BEFORE touching anything, then tamper check, then restore
    run(["git", "add", "-A"], cwd=repo_dir, timeout=120)
    patch = run(["git", "diff", "--cached", "--binary"], cwd=repo_dir, timeout=120).out
    run(["git", "reset", "-q"], cwd=repo_dir, timeout=120)
    patch_path = os.path.join(run_dir, "patch.diff")
    with open(patch_path, "w", encoding="utf-8") as fh:
        fh.write(patch)
    tampered = run(["git", "diff", "--name-only", "HEAD", "--"] + hidden_files, cwd=repo_dir, timeout=60).out.split()
    missing = [f for f in hidden_files if not os.path.isfile(os.path.join(repo_dir, f))]
    tampered = sorted(set(tampered) | set(missing))
    run(["git", "checkout", "HEAD", "--"] + hidden_files, cwd=repo_dir, timeout=60)

    # 2. build, vet, hidden tests, full suite, gofmt
    t_build = int(repo_cfg.get("build_timeout_s", 900))
    build = run(["go", "build", "./..."], cwd=repo_dir, env=env, timeout=t_build)
    vet = run(["go", "vet", "./..."], cwd=repo_dir, env=env, timeout=t_build) if build.ok else None
    # vet is judged relative to the base commit: a finding the author's own tree already had
    # (measured: two on k6 with Go 1.27's vet, in files no agent touches) is not the agent's.
    base_vet = task.get("verify", {}).get("vet_base_findings")
    vet_new: List[str] = []
    vet_mode = "relative" if base_vet is not None else "absolute"
    if vet is not None and not vet.ok:
        vet_new = [f for f in vet_findings(vet.err) if f not in set(base_vet or [])]
    vet_ok_rel = bool(vet and (vet.ok or (vet_mode == "relative" and not vet_new)))
    hidden = None
    full = None
    if build.ok:
        hidden, _ = run_tests(repo_dir, env, list(task["hidden_tests"]["packages"]), task["hidden_tests"].get("run_regex"),
                              list(repo_cfg.get("test_extra_args") or []), int(repo_cfg.get("hidden_timeout_s", 600)))
        pkgs = list_packages(repo_dir, env, repo_cfg.get("exclude_pkg_regex"))
        extra = list(repo_cfg.get("test_extra_args") or [])
        skip = task.get("verify", {}).get("skip_regex") or repo_cfg.get("skip_regex")
        if skip:
            extra += ["-skip", skip]
        full, _ = run_tests(repo_dir, env, pkgs, None, extra, int(repo_cfg.get("suite_timeout_s", 1500)),
                            repo_cfg.get("parallel_p"))
        # A test that fails in the full suite and passes when rerun alone is a flake (measured
        # on the full run: websockets.TestLockingUpWithAJustGeneralCancel failed once in an
        # untouched package under two-lane load after passing 6/6 in curation). Failed tests
        # are rerun once in isolation; the retry is recorded either way. Build failures and
        # hidden tests are never retried.
        full["flaky_retry"] = None
        full["unrelated_failed_packages"] = None
        if full and not full["pass"] and full["failed_packages"] and not full["build_failed_packages"]:
            # a failure confined to packages that do not depend on anything the agent changed
            # is the environment's (hang, flake), not the arm's: rerun those packages once whole
            changed = run(["git", "diff", "--name-only", "HEAD"], cwd=repo_dir, timeout=60).out.split() + \
                      run(["git", "ls-files", "--others", "--exclude-standard"], cwd=repo_dir, timeout=60).out.split()
            touched = touched_import_paths(repo_dir, env, changed)
            unrelated, related = unrelated_failed_packages(repo_dir, env, full["failed_packages"], touched)
            full["unrelated_failed_packages"] = {"unrelated": unrelated, "related": related, "touched": touched}
            if unrelated and not related:
                rr, _ = run_tests(repo_dir, env, unrelated, None, [a for a in extra if a not in ("-timeout",) and not a.endswith("s")] + ["-timeout", "600s"],
                                  int(repo_cfg.get("hidden_timeout_s", 600)))
                full["unrelated_retry"] = {"packages": unrelated, "pass": rr["pass"], "failed": rr["failed_tests"][:10], "seconds": rr["seconds"]}
                if rr["pass"]:
                    full["failed_tests_before_retry"] = full["failed_tests"]
                    full["failed_packages_before_retry"] = full["failed_packages"]
                    full["pass"] = True
                    notes.append("full suite passed after rerunning unrelated package(s) %s once" % unrelated)
                else:
                    full["env_failure"] = "suite_failure_in_unrelated_package"
                    notes.append("full suite failure confined to package(s) with no dependency on the change: %s" % unrelated)
        if full and not full["pass"] and full["failed_tests"] and not full["build_failed_packages"] and not full["timed_out"] and not full.get("env_failure"):
            groups = rerun_groups(full["failed_tests"])
            retry_ok = True
            retried = []
            for pkg, names in groups.items():
                rr, _ = run_tests(repo_dir, env, [pkg], "^(%s)$" % "|".join(sorted(set(names))), extra,
                                  int(repo_cfg.get("hidden_timeout_s", 600)))
                retried.append({"package": pkg, "tests": sorted(set(names)), "pass": rr["pass"], "failed": rr["failed_tests"][:10]})
                retry_ok = retry_ok and rr["pass"]
            full["flaky_retry"] = {"groups": retried, "all_passed_on_retry": retry_ok}
            if retry_ok and not full["failed_packages"] == []:
                full["failed_packages_before_retry"] = full["failed_packages"]
            if retry_ok:
                full["failed_tests_before_retry"] = full["failed_tests"]
                full["pass"] = True
                notes.append("full suite passed after a one-time isolated rerun of %d flaky test(s)" % sum(len(g["tests"]) for g in retried))
    changed_go = [p for p in run(["git", "diff", "--name-only", "HEAD"], cwd=repo_dir, timeout=60).out.split()
                  if p.endswith(".go") and os.path.isfile(os.path.join(repo_dir, p))]
    untracked_go = [p for p in run(["git", "ls-files", "--others", "--exclude-standard"], cwd=repo_dir, timeout=60).out.split()
                    if p.endswith(".go")]
    gofmt_files = sorted(set(changed_go + untracked_go))
    gofmt = run(["gofmt", "-l"] + gofmt_files, cwd=repo_dir, env=env, timeout=120) if gofmt_files else None
    gofmt_dirty = gofmt.out.split() if gofmt else []

    # 3. diff stats
    dstats = diff_stats(patch, task.get("author_patch", {}).get("files_code", []))

    # 4/5. Claude accounting first (the write attribution needs to know whether a
    # delegation was backgrounded), then the gate log
    result = claude_usage.parse_result(os.path.join(raw, "result.json"))
    transcripts = sorted(glob.glob(os.path.join(raw, "transcripts", "*.jsonl")))
    tsum = {"present": False}
    agy_calls: List[dict] = []
    if transcripts:
        main_t = [t for t in transcripts if os.path.basename(t).startswith("main")] or transcripts[:1]
        tsum = claude_usage.summarize_transcript(main_t[0])
        agy_calls = list(tsum.get("agy_calls") or [])
    writes = attribute_writes(os.path.join(raw, "tool_trace.jsonl"), bool(tsum.get("background_delegations") or tsum.get("bash_cap_backgrounds")))
    if transcripts:
        for extra_t in transcripts:
            if extra_t == main_t[0]:
                continue
            sub = claude_usage.summarize_transcript(extra_t)
            for k in ("input", "output", "cache_creation", "cache_read", "turns", "web_tool_calls", "write_tool_calls"):
                tsum[k] = tsum.get(k, 0) + sub.get(k, 0)
            for name, n in sub.get("tool_calls", {}).items():
                tsum["tool_calls"][name] = tsum["tool_calls"].get(name, 0) + n
            agy_calls.extend(sub.get("agy_calls") or [])
    recomputed, price_flags = claude_usage.recompute_list_price(result.get("model_usage") or {}, prices)
    lc = claude_usage.long_context_estimate(transcripts[0], prices) if transcripts else {}
    recon = claude_usage.reconcile(result, tsum) if tsum.get("present") else {"ok": None, "fields": {}}
    cost_gap = None
    if recomputed is not None and result.get("total_cost_usd"):
        cost_gap = round((recomputed - float(result["total_cost_usd"])) / float(result["total_cost_usd"]), 4)
    conductor_models = sorted((result.get("model_usage") or {}).keys())

    # 6. agy accounting
    agy_recs = agy_usage.parse_log(os.path.join(raw, "agy_usage.log"))
    try:
        agy = agy_usage.summarize(agy_recs, prices, agy_calls)
    except agy_usage.InvariantError as e:
        agy = {"delegations": None, "invariant_ok": False, "error": str(e), "shadow_usd": None, "conversation_ids": []}
        notes.append("AGY_USAGE invariant violated: %s" % e)
    audits = {cid: audit_brain(cid) for cid in (agy.get("conversation_ids") or [])}
    executor_web = any(a.get("web_steps", 0) > 0 for a in audits.values())
    agy["trace_audit"] = audits
    agy["executor_web_access"] = executor_web
    agy["executor_write_steps"] = sum(a.get("write_steps", 0) for a in audits.values())

    # 7. outcome
    build_ok = build.ok
    vet_ok = vet_ok_rel
    hidden_pass = bool(hidden and hidden["pass"])
    full_pass = bool(full and full["pass"])
    tree_pass = build_ok and vet_ok and hidden_pass and full_pass
    subtype = result.get("subtype")
    if meta.get("killed_wall"):
        subtype = "killed_wall"
    capped = subtype in ("killed_wall", "error_max_turns", "error_max_budget_usd")
    # protocol: a run that hit a cap counts as a failure even if the tree it left passes
    passed = tree_pass and not capped
    claude_usd = float(result["total_cost_usd"]) if result.get("total_cost_usd") is not None else None
    claude_usd_source = "result.modelUsage"
    if claude_usd is None and tsum.get("present"):
        # killed runs leave no result object; the transcript's per-request usage is exact and
        # the same numbers Claude Code prices, so the deck reproduces its figure (checked on
        # completed runs: |gap| < 0.1%).
        tot = 0.0
        for m, mu in (tsum.get("models") or {}).items():
            usd, _ = prices.price_claude(m, mu["input"], mu["output"], mu["cache_creation"], mu["cache_read"])
            tot += usd or 0.0
        if tot > 0:
            claude_usd = round(tot, 6)
            claude_usd_source = "transcript_list_price"
            notes.append("Claude $ recomputed from the transcript (no result object: %s)" % subtype)
    gemini_usd = agy.get("shadow_usd")
    total_usd = (claude_usd or 0.0) + (gemini_usd or 0.0) if claude_usd is not None else None

    violations: List[str] = []
    env_failure = (full or {}).get("env_failure") if full else None
    if arm.startswith("hybrid") and not (agy.get("delegations") or 0) and tsum.get("wrapper_not_found"):
        env_failure = "plugin_bin_missing"  # the arm's only write path was absent: an environment failure, rerun
        notes.append("agy-delegate was not on the agent's PATH; no delegation possible")
    if arm.startswith("hybrid") and not (agy.get("usage_lines") or 0) and tsum.get("bash_cap_backgrounds"):
        env_failure = "bash_cap_backgrounded_delegation"  # Claude Code moved the delegation past the Bash timeout into the background; headless has no later turn to collect it
        notes.append("the delegation was moved to the background by the Bash timeout cap and never collected")
    if tsum.get("web_tool_calls"):
        violations.append("claude_web_tool_call")
    if executor_web:
        violations.append("executor_web_access")
    if arm == "hybrid-forced" and (writes.get("claude_bash") or tsum.get("write_tool_calls")):
        violations.append("claude_side_write_in_forced_arm")

    rec = {
        "schema": "bench.run/1",
        "run_id": meta.get("run_id"), "run_key": meta.get("run_key"), "task_id": task["task_id"], "arm": arm,
        "rep": meta.get("rep"), "attempt": meta.get("attempt", 1), "lane": meta.get("lane"),
        "size_class": task.get("size_class"),
        "status": "ok", "failure_class": None, "env_failure": env_failure, "violations": violations,
        "started_at": meta.get("started_at"), "ended_at": meta.get("ended_at"),
        "agent_wall_s": meta.get("agent_wall_s"), "agent_active_s": meta.get("agent_active_s"),
        "suspended_s": meta.get("suspended_s", 0.0),
        "versions": meta.get("versions", {}),
        "conductor": {"model_alias": meta.get("conductor_alias"), "model_ids": conductor_models,
                      "effort": meta.get("effort")},
        "executor": meta.get("executor", {}),
        "caps": meta.get("caps", {}),
        "prompt": meta.get("prompt", {}),
        "claude": {
            "session_id": result.get("session_id"), "subtype": subtype, "is_error": result.get("is_error"),
            "num_turns": result.get("num_turns") or (tsum.get("turns") if tsum.get("present") else None),
            "num_turns_source": "result" if result.get("num_turns") else "transcript",
            "duration_ms": result.get("duration_ms"),
            "duration_api_ms": result.get("duration_api_ms"), "total_cost_usd": claude_usd,
            "total_cost_usd_source": claude_usd_source, "capped": capped,
            "usage": result.get("usage"), "model_usage": result.get("model_usage"),
            "list_price_usd_recomputed": None if recomputed is None else round(recomputed, 6),
            "recomputed_vs_reported_gap": cost_gap, "price_flags": price_flags,
            "long_context": lc,
            "transcript": {k: tsum.get(k) for k in ("present", "turns", "input", "output", "cache_creation",
                                                     "cache_read", "first_turn_cache_read", "models",
                                                     "tool_calls", "web_tool_calls", "write_tool_calls",
                                                     "sidechain_turns", "background_delegations", "bash_cap_backgrounds")},
            "warm_start": bool(tsum.get("first_turn_cache_read")),
            "usage_reconciles": recon.get("ok"), "usage_reconciliation": recon.get("fields"),
            "permission_denials": len(result.get("permission_denials") or []),
            "denied_tools": _count_denials(result.get("permission_denials") or []),
            "result_head": result.get("result_head"), "errors": result.get("errors"),
        },
        "agy": agy,
        "writes": writes,
        "outcome": {
            "build_ok": build_ok, "build_stderr_tail": build.err[-1500:] if not build_ok else "",
            "vet_ok": vet_ok, "vet_mode": vet_mode, "vet_new_findings": vet_new[:20],
            "vet_stderr_tail": (vet.err[-1500:] if vet and not vet.ok else ""),
            "gofmt_clean": not gofmt_dirty, "gofmt_dirty_files": gofmt_dirty,
            "hidden_tests": _slim(hidden), "full_suite": _slim(full),
            "hidden_pass": hidden_pass, "tree_pass": tree_pass, "pass": passed,
            "hidden_test_tampered": bool(tampered), "tampered_files": tampered,
        },
        "diff": {k: v for k, v in dstats.items() if k != "files"},
        "diff_files": dstats["files"],
        "cost": {"claude_usd": claude_usd, "gemini_usd": gemini_usd, "total_usd": total_usd},
        "notes": notes,
    }
    write_json(os.path.join(run_dir, "run.json"), rec)
    return rec


def rerun_groups(failed_tests: List[str]) -> Dict[str, List[str]]:
    """'pkg.TestX/sub' entries -> {pkg: [top-level test names]} for an isolated rerun."""
    groups: Dict[str, List[str]] = {}
    for f in failed_tests:
        pkg, _, name = f.rpartition(".")
        top = name.split("/", 1)[0]
        if pkg and top:
            groups.setdefault(pkg, [])
            if top not in groups[pkg]:
                groups[pkg].append(top)
    return groups


def vet_findings(stderr: str) -> List[str]:
    """`path: message` per vet finding, line/column dropped so an edit above it does not
    turn an inherited finding into a new one."""
    out: List[str] = []
    for line in stderr.splitlines():
        m = re.match(r"^(\S+?\.go):\d+(?::\d+)?:\s*(.*)$", line.strip())
        if m:
            key = "%s: %s" % (m.group(1), m.group(2).strip())
            if key not in out:
                out.append(key)
    return out


def _count_denials(denials: List[dict]) -> Dict[str, int]:
    out: Dict[str, int] = {}
    for d in denials:
        name = str(d.get("tool_name") or "?")
        if name == "Bash":
            cmd = str((d.get("tool_input") or {}).get("command") or "").strip()
            name = "Bash:" + (cmd.split()[0] if cmd else "?")
        out[name] = out.get(name, 0) + 1
    return out


def _slim(t: Optional[dict]) -> Optional[dict]:
    if t is None:
        return None
    return {k: t.get(k) for k in ("pass", "rc", "timed_out", "seconds", "passed_tests", "failed_tests",
                                  "failed_packages", "build_failed_packages", "packages", "stderr_tail",
                                  "flaky_retry", "failed_tests_before_retry", "failed_packages_before_retry",
                                  "unrelated_failed_packages", "unrelated_retry", "env_failure")}


def reaccount(run_dir: str, task: dict, arm: str, prices: Prices) -> dict:
    """Recompute the accounting sections of an existing run.json from raw/ without touching
    the tree: Claude/agy costs, write attribution, the relative vet rule (from the saved vet
    stderr) and the capped-run rule. Used after a harness fix so old records follow the
    same definitions as new ones; the test outcomes themselves are never re-derived here."""
    raw = os.path.join(run_dir, "raw")
    rec = read_json(os.path.join(run_dir, "run.json"))
    meta = read_json(os.path.join(raw, "meta.json")) if os.path.isfile(os.path.join(raw, "meta.json")) else {}
    result = claude_usage.parse_result(os.path.join(raw, "result.json"))
    transcripts = sorted(glob.glob(os.path.join(raw, "transcripts", "*.jsonl")))
    tsum = {"present": False}
    agy_calls: List[dict] = []
    if transcripts:
        main_t = [t for t in transcripts if os.path.basename(t).startswith("main")] or transcripts[:1]
        tsum = claude_usage.summarize_transcript(main_t[0])
        agy_calls = list(tsum.get("agy_calls") or [])
    recomputed, price_flags = claude_usage.recompute_list_price(result.get("model_usage") or {}, prices)
    lc = claude_usage.long_context_estimate(transcripts[0], prices) if transcripts else {}
    claude_usd = float(result["total_cost_usd"]) if result.get("total_cost_usd") is not None else None
    source = "result.modelUsage"
    if claude_usd is None and tsum.get("present"):
        tot = sum((prices.price_claude(m, mu["input"], mu["output"], mu["cache_creation"], mu["cache_read"])[0] or 0.0)
                  for m, mu in (tsum.get("models") or {}).items())
        if tot > 0:
            claude_usd, source = round(tot, 6), "transcript_list_price"
    agy_recs = agy_usage.parse_log(os.path.join(raw, "agy_usage.log"))
    try:
        agy = agy_usage.summarize(agy_recs, prices, agy_calls)
    except agy_usage.InvariantError as e:
        agy = {"delegations": None, "invariant_ok": False, "error": str(e), "shadow_usd": None, "conversation_ids": []}
    audits = {cid: audit_brain(cid) for cid in (agy.get("conversation_ids") or [])}
    agy["trace_audit"] = audits
    agy["executor_web_access"] = any(a.get("web_steps", 0) > 0 for a in audits.values())
    agy["executor_write_steps"] = sum(a.get("write_steps", 0) for a in audits.values())
    writes = attribute_writes(os.path.join(raw, "tool_trace.jsonl"), bool(tsum.get("background_delegations") or tsum.get("bash_cap_backgrounds")))
    rec["claude"].setdefault("transcript", {})["background_delegations"] = tsum.get("background_delegations")
    rec["claude"]["transcript"]["bash_cap_backgrounds"] = tsum.get("bash_cap_backgrounds")
    o = rec["outcome"]
    base_vet = task.get("verify", {}).get("vet_base_findings")
    vet_new = [f for f in vet_findings(o.get("vet_stderr_tail") or "") if f not in set(base_vet or [])]
    vet_ok = bool(o.get("vet_ok")) or (base_vet is not None and o.get("build_ok") and not vet_new)
    tree_pass = bool(o.get("build_ok") and vet_ok and o.get("hidden_pass") and (o.get("full_suite") or {}).get("pass"))
    subtype = result.get("subtype") or ("killed_wall" if meta.get("killed_wall") else rec["claude"].get("subtype"))
    capped = subtype in ("killed_wall", "error_max_turns", "error_max_budget_usd")
    violations: List[str] = []
    if tsum.get("web_tool_calls"):
        violations.append("claude_web_tool_call")
    if agy["executor_web_access"]:
        violations.append("executor_web_access")
    if arm == "hybrid-forced" and (writes.get("claude_bash") or tsum.get("write_tool_calls")):
        violations.append("claude_side_write_in_forced_arm")
    rec["env_failure"] = ("plugin_bin_missing" if (arm.startswith("hybrid") and not (agy.get("delegations") or 0) and tsum.get("wrapper_not_found"))
                          else "bash_cap_backgrounded_delegation" if (arm.startswith("hybrid") and not (agy.get("usage_lines") or 0) and tsum.get("bash_cap_backgrounds"))
                          else None)
    gemini_usd = agy.get("shadow_usd")
    rec["claude"].update({"total_cost_usd": claude_usd, "total_cost_usd_source": source, "subtype": subtype, "capped": capped,
                          "num_turns": result.get("num_turns") or (tsum.get("turns") if tsum.get("present") else None),
                          "list_price_usd_recomputed": None if recomputed is None else round(recomputed, 6), "price_flags": price_flags,
                          "long_context": lc})
    rec["agy"] = agy
    rec["writes"] = writes
    o.update({"vet_ok": vet_ok, "vet_mode": "relative" if base_vet is not None else "absolute", "vet_new_findings": vet_new[:20],
              "tree_pass": tree_pass, "pass": tree_pass and not capped})
    rec["violations"] = violations
    rec["cost"] = {"claude_usd": claude_usd, "gemini_usd": gemini_usd,
                   "total_usd": (claude_usd or 0.0) + (gemini_usd or 0.0) if claude_usd is not None else None}
    rec.setdefault("notes", []).append("reaccounted at %s" % __import__("common").now_iso())
    write_json(os.path.join(run_dir, "run.json"), rec)
    return rec
