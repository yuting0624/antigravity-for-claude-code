"""Task curation: turn a merged PR (or a stack of them) into a replayable task.

    bench.py curate mirror  <owner/repo>
    bench.py curate make    <owner/repo> --prs 7913 --task-id caddy-7913 [--size medium]
    bench.py curate make    cli/cli --prs 14177-14184 --task-id cli-attach-stack
    bench.py curate verify  <task-id>        # fail-at-base, 3x green at target, timings
    bench.py curate lint    <task-id>        # prompt.md leaks nothing from the author patch
    bench.py curate prewarm <task-id>        # module + build caches for base and target

`make` writes task.json, tests.list, hidden/<paths>, author.patch, author_full.patch and a
prompt.draft.md (PR body + file list, for the human who writes prompt.md). `verify` and
`lint` refuse to bless a task that would not measure what it claims to.
"""
from __future__ import annotations

import json
import os
import re
import shutil
import statistics
import subprocess
from typing import Dict, List, Optional, Tuple

import score as score_mod
from common import (GOBUILD_DIR, GOMOD_DIR, MIRRORS_DIR, TASKS_DIR, WORK_DIR, classify_path, ensure_dirs,
                    is_test_path, now_iso, read_json, read_text, run, sha256_text, size_class, write_json,
                    write_text)

TEST_FUNC_RE = re.compile(r"^func (Test\w+|Example\w*|Benchmark\w+|Fuzz\w+)\(", re.M)


def gh(args: List[str], timeout: int = 120) -> str:
    r = run(["gh"] + args, timeout=timeout)
    if not r.ok:
        raise RuntimeError("gh %s failed: %s" % (" ".join(args[:3]), r.err[-400:]))
    return r.out


def mirror_path(repo: str) -> str:
    return os.path.join(MIRRORS_DIR, repo.replace("/", "__") + ".git")


def ensure_mirror(repo: str) -> str:
    ensure_dirs()
    m = mirror_path(repo)
    if not os.path.isdir(m):
        r = run(["git", "clone", "-q", "--mirror", "https://github.com/%s.git" % repo, m], timeout=3600)
        if not r.ok:
            raise RuntimeError("mirror clone failed: %s" % r.err[-400:])
    r = run(["git", "-C", m, "fetch", "-q", "--prune", "origin"], timeout=3600)
    if not r.ok:
        raise RuntimeError("mirror fetch failed: %s" % r.err[-400:])
    return m


def pr_meta(repo: str, number: int) -> dict:
    d = json.loads(gh(["api", "repos/%s/pulls/%d" % (repo, number)]))
    files = json.loads(gh(["api", "repos/%s/pulls/%d/files" % (repo, number), "--paginate", "--slurp"]))
    flat: List[dict] = []
    for page in files:
        flat.extend(page if isinstance(page, list) else [page])
    commits = json.loads(gh(["api", "repos/%s/pulls/%d/commits" % (repo, number), "--paginate", "--slurp"]))
    cflat: List[dict] = []
    for page in commits:
        cflat.extend(page if isinstance(page, list) else [page])
    return {"number": number, "url": d.get("html_url"), "title": d.get("title"), "body": d.get("body") or "",
            "merged_at": d.get("merged_at"), "merge_commit": d.get("merge_commit_sha"),
            "head_sha": (d.get("head") or {}).get("sha"), "author": (d.get("user") or {}).get("login"),
            "commits": int(d.get("commits") or len(cflat)), "additions": d.get("additions"),
            "deletions": d.get("deletions"), "changed_files": d.get("changed_files"),
            "files": [{"filename": f.get("filename"), "status": f.get("status"), "additions": f.get("additions"),
                       "deletions": f.get("deletions"), "previous_filename": f.get("previous_filename")} for f in flat],
            "commit_messages": [str((c.get("commit") or {}).get("message") or "").splitlines()[0] for c in cflat]}


def merge_method(mirror: str, pr: dict) -> Tuple[str, str]:
    """(method, base_sha). merge: 2 parents; rebase: N linear commits; squash: 1 commit."""
    sha = pr["merge_commit"]
    parents = run(["git", "-C", mirror, "rev-list", "--parents", "-n", "1", sha], timeout=60).out.split()[1:]
    if len(parents) >= 2:
        return "merge", parents[0]
    n = pr["commits"]
    if n > 1:
        first_msg = run(["git", "-C", mirror, "log", "-1", "--format=%s", "%s~%d" % (sha, n - 1)], timeout=60).out.strip()
        if first_msg and pr["commit_messages"] and first_msg == pr["commit_messages"][0]:
            return "rebase", run(["git", "-C", mirror, "rev-parse", "%s~%d" % (sha, n)], timeout=60).out.strip()
    return "squash", parents[0]


def _parse_prs(spec: str) -> List[int]:
    out: List[int] = []
    for part in spec.split(","):
        part = part.strip()
        if "-" in part:
            a, b = part.split("-", 1)
            out.extend(range(int(a), int(b) + 1))
        elif part:
            out.append(int(part))
    return out


def make(repo: str, prs_spec: str, task_id: str, size_override: Optional[str] = None) -> str:
    mirror = ensure_mirror(repo)
    numbers = _parse_prs(prs_spec)
    metas = [pr_meta(repo, n) for n in numbers]
    metas.sort(key=lambda m: m["merged_at"] or "")
    first, last = metas[0], metas[-1]
    method, base_sha = merge_method(mirror, first)
    target = last["merge_commit"]
    # file set = union over PRs, classified from the target tree
    seen: Dict[str, dict] = {}
    for m in metas:
        for f in m["files"]:
            seen[f["filename"]] = f
    files = sorted(seen)
    files_test = [f for f in files if is_test_path(f)]
    files_code = [f for f in files if classify_path(f) == "code"]
    files_other = [f for f in files if f not in files_test and f not in files_code]
    # confirm the git range reproduces the PR file set
    range_files = set(run(["git", "-C", mirror, "diff", "--name-only", "%s..%s" % (base_sha, target)], timeout=120).out.split())
    mismatch = sorted(set(files) ^ range_files)
    repo_dir_name = repo.replace("/", "__")
    task_dir = os.path.join(TASKS_DIR, repo_dir_name, task_id)
    os.makedirs(os.path.join(task_dir, "hidden"), exist_ok=True)
    # hidden test files at the target commit (deleted-in-PR test files cannot be hidden tests)
    hidden: List[str] = []
    for f in files_test:
        blob = run(["git", "-C", mirror, "cat-file", "-e", "%s:%s" % (target, f)], timeout=60)
        if not blob.ok:
            continue
        content = run(["git", "-C", mirror, "show", "%s:%s" % (target, f)], timeout=60).out
        dst = os.path.join(task_dir, "hidden", f)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        write_text(dst, content)
        hidden.append(f)
    funcs, pkgs = _hidden_funcs(mirror, base_sha, target, hidden)
    # author patch stats (non-test .go added lines, generated files excluded)
    numstat = run(["git", "-C", mirror, "diff", "--numstat", "%s..%s" % (base_sha, target)], timeout=120).out
    code_added = code_removed = test_added = test_removed = 0
    generated: List[str] = []
    for line in numstat.splitlines():
        parts = line.split("\t")
        if len(parts) < 3 or parts[0] == "-":
            continue
        a, d, path = int(parts[0]), int(parts[1]), parts[2]
        c = classify_path(path)
        if c == "code":
            head = run(["git", "-C", mirror, "show", "%s:%s" % (target, path)], timeout=60).out[:400]
            if "Code generated" in head and "DO NOT EDIT" in head:
                generated.append(path)
                continue
            code_added += a; code_removed += d
        elif c == "test":
            test_added += a; test_removed += d
    author_patch = run(["git", "-C", mirror, "diff", "--binary", "%s..%s" % (base_sha, target), "--"] + [f for f in files_code if f not in generated], timeout=120).out
    author_full = run(["git", "-C", mirror, "diff", "--binary", "%s..%s" % (base_sha, target)], timeout=120).out
    write_text(os.path.join(task_dir, "author.patch"), author_patch)
    write_text(os.path.join(task_dir, "author_full.patch"), author_full)
    write_text(os.path.join(task_dir, "tests.list"), "\n".join(hidden) + "\n")
    go_directive = _go_directive(mirror, target)
    gomod_changed = bool(run(["git", "-C", mirror, "diff", "--quiet", "%s..%s" % (base_sha, target), "--", "go.mod", "go.sum"], timeout=60).rc)
    task = {
        "schema": "bench.task/1", "task_id": task_id, "repo": repo, "repo_url": "https://github.com/" + repo,
        "license": _license(repo),
        "prs": [{"number": m["number"], "url": m["url"], "title": m["title"], "merged_at": m["merged_at"],
                 "author": m["author"], "merge_commit": m["merge_commit"], "head_sha": m["head_sha"],
                 "commits": m["commits"]} for m in metas],
        "merge_method_first": method, "base_sha": base_sha, "target_sha": target, "go_directive": go_directive,
        "size_class": size_override or size_class(code_added),
        "author_patch": {"code_added": code_added, "code_removed": code_removed, "test_added": test_added,
                         "test_removed": test_removed, "files_code": [f for f in files_code if f not in generated],
                         "files_generated": generated, "files_test": files_test, "files_other": files_other},
        "hidden_tests": {"files": hidden, "funcs": funcs, "packages": pkgs,
                         "run_regex": "^(%s)$" % "|".join(sorted(set(funcs))) if funcs else None, "base_status": None},
        "verify": {"status": "unverified"},
        "deps": {"go_mod_changed": gomod_changed},
        "range_vs_pr_files_mismatch": mismatch,
        "prompt": {"sha256": None, "lines": None, "lint": None},
        "curated_at": now_iso(),
    }
    write_json(os.path.join(task_dir, "task.json"), task)
    draft = ["# DRAFT — write prompt.md from this by hand; this file is never shown to an agent", ""]
    for m in metas:
        draft += ["## PR #%d %s (merged %s)" % (m["number"], m["title"], m["merged_at"]), "", m["body"], ""]
    draft += ["## Files (code)", ""] + ["- " + f for f in files_code] + ["", "## Hidden tests", ""] + ["- " + f for f in hidden]
    draft += ["", "## Test functions", ""] + ["- " + f for f in funcs]
    write_text(os.path.join(task_dir, "prompt.draft.md"), "\n".join(draft) + "\n")
    return task_dir


def _license(repo: str) -> Optional[str]:
    try:
        return json.loads(gh(["api", "repos/%s" % repo])).get("license", {}).get("spdx_id")
    except Exception:  # noqa: BLE001
        return None


def _go_directive(mirror: str, sha: str) -> Optional[str]:
    gomod = run(["git", "-C", mirror, "show", "%s:go.mod" % sha], timeout=60).out
    m = re.search(r"^go\s+(\S+)", gomod, re.M)
    return m.group(1) if m else None


def _hidden_funcs(mirror: str, base: str, target: str, hidden: List[str]) -> Tuple[List[str], List[str]]:
    """Test functions that are new or whose file changed; packages that hold them."""
    funcs: List[str] = []
    pkgs: List[str] = []
    for f in hidden:
        if not f.endswith("_test.go"):
            continue
        new = run(["git", "-C", mirror, "show", "%s:%s" % (target, f)], timeout=60).out
        old = run(["git", "-C", mirror, "show", "%s:%s" % (base, f)], timeout=60).out
        new_funcs = TEST_FUNC_RE.findall(new)
        if old:
            # a changed file: every test in it is a hidden test (its body may have changed)
            funcs.extend(new_funcs)
        else:
            funcs.extend(new_funcs)
        pkg = "./" + os.path.dirname(f) if os.path.dirname(f) else "./"
        if pkg not in pkgs:
            pkgs.append(pkg)
    return sorted(set(funcs)), pkgs


# ------------------------------------------------------------------ verify --

def _worktree(mirror: str, sha: str, name: str) -> str:
    d = os.path.join(WORK_DIR, "curate", name)
    if os.path.isdir(d):
        shutil.rmtree(d)
    os.makedirs(os.path.dirname(d), exist_ok=True)
    r = run(["git", "clone", "-q", "--shared", "--no-checkout", mirror, d], timeout=600)
    if not r.ok:
        raise RuntimeError(r.err[-300:])
    r = run(["git", "checkout", "-q", "--detach", sha], cwd=d, timeout=600)
    if not r.ok:
        raise RuntimeError(r.err[-300:])
    return d


def prewarm(task_id: str) -> dict:
    from common import load_task
    task, task_dir = load_task(task_id)
    repo_cfg = read_json(os.path.join(os.path.dirname(task_dir), "repo.json"))
    mirror = mirror_path(task["repo"])
    env = score_mod.go_env(repo_cfg, GOMOD_DIR, GOBUILD_DIR)
    env_online = dict(env); env_online["GOPROXY"] = "https://proxy.golang.org,direct"; env_online["GOSUMDB"] = "sum.golang.org"
    out = {}
    for label, sha in (("base", task["base_sha"]), ("target", task["target_sha"])):
        d = _worktree(mirror, sha, "%s-%s" % (task_id, label))
        r1 = run(["go", "mod", "download", "all"], cwd=d, env=env_online, timeout=1800)
        r2 = run(["go", "build", "./..."], cwd=d, env=env, timeout=1800)
        r3 = run(["go", "vet", "./..."], cwd=d, env=env, timeout=1800)
        r4 = run(["go", "test", "-count=1", "-run", "^$", "./..."], cwd=d, env=env, timeout=1800)
        out[label] = {"download_ok": r1.ok, "build_ok": r2.ok, "vet_ok": r3.ok, "test_compile_ok": r4.ok,
                      "seconds": round(r1.seconds + r2.seconds + r3.seconds + r4.seconds, 1),
                      "errors": (r1.err + r2.err + r3.err + r4.err)[-1500:] if not (r1.ok and r2.ok and r4.ok) else ""}
        shutil.rmtree(d, ignore_errors=True)
    task.setdefault("verify", {})["prewarm"] = out
    write_json(os.path.join(task_dir, "task.json"), task)
    return out


def verify(task_id: str, suite_runs: int = 3) -> dict:
    from common import load_task
    task, task_dir = load_task(task_id)
    repo_cfg = read_json(os.path.join(os.path.dirname(task_dir), "repo.json"))
    mirror = mirror_path(task["repo"])
    env = score_mod.go_env(repo_cfg, GOMOD_DIR, GOBUILD_DIR)
    ht = task["hidden_tests"]
    report: dict = {"checked_at": now_iso()}
    # 1. base + hidden tests must fail (compile failure counts)
    base = _worktree(mirror, task["base_sha"], task_id + "-vbase")
    for rel in ht["files"]:
        dst = os.path.join(base, rel)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        shutil.copyfile(os.path.join(task_dir, "hidden", rel), dst)
    hb, _ = score_mod.run_tests(base, env, ht["packages"], ht.get("run_regex"), list(repo_cfg.get("test_extra_args") or []),
                                int(repo_cfg.get("hidden_timeout_s", 600)))
    if hb["build_failed_packages"] or hb["rc"] != 0 and not hb["failed_tests"]:
        base_status = "compile_fail"
    elif hb["failed_tests"]:
        base_status = "fail"
    else:
        base_status = "pass"
    report["base"] = {"status": base_status, "failed_tests": hb["failed_tests"][:20], "passed_tests": hb["passed_tests"], "seconds": hb["seconds"]}
    shutil.rmtree(base, ignore_errors=True)
    # 2. target: hidden tests pass, full suite green N times
    tgt = _worktree(mirror, task["target_sha"], task_id + "-vtarget")
    ht_t, _ = score_mod.run_tests(tgt, env, ht["packages"], ht.get("run_regex"), list(repo_cfg.get("test_extra_args") or []),
                                  int(repo_cfg.get("hidden_timeout_s", 600)))
    report["target_hidden"] = {"pass": ht_t["pass"], "failed_tests": ht_t["failed_tests"][:20], "passed_tests": ht_t["passed_tests"]}
    pkgs = score_mod.list_packages(tgt, env, repo_cfg.get("exclude_pkg_regex"))
    times: List[float] = []
    fails: Dict[str, int] = {}
    for _ in range(suite_runs):
        full, _ = score_mod.run_tests(tgt, env, pkgs, None, list(repo_cfg.get("test_extra_args") or []),
                                      int(repo_cfg.get("suite_timeout_s", 1500)), repo_cfg.get("parallel_p"))
        times.append(full["seconds"])
        for t in full["failed_tests"] + ["pkg:" + p for p in full["failed_packages"]]:
            fails[t] = fails.get(t, 0) + 1
    flaky = sorted(t for t, n in fails.items() if 0 < n < suite_runs)
    always = sorted(t for t, n in fails.items() if n == suite_runs)
    shutil.rmtree(tgt, ignore_errors=True)
    report["target_suite"] = {"runs": suite_runs, "median_s": statistics.median(times), "flaky": flaky, "always_failing": always,
                              "packages": len(pkgs)}
    def fn(name: str) -> str:  # "pkg.TestX/sub" -> "TestX"
        return name.rsplit(".", 1)[-1].split("/", 1)[0]
    hidden_set = set(ht["funcs"])
    hidden_flaky = sorted({fn(f) for f in flaky if not f.startswith("pkg:") and fn(f) in hidden_set})
    hidden_always = sorted({fn(f) for f in always if not f.startswith("pkg:") and fn(f) in hidden_set})
    # Tests that fail with the author's own patch (3/3) cannot tell the arms apart: they are
    # environment failures on this machine and are skipped in the full-suite gate, recorded
    # here. A flaky HIDDEN test is dropped from the hidden set (recorded), never kept.
    env_fail = sorted({fn(f) for f in always if not f.startswith("pkg:")} - hidden_set)
    skip_funcs = sorted({fn(f) for f in flaky if not f.startswith("pkg:")} | set(env_fail) | set(hidden_flaky))
    if hidden_flaky:
        ht["funcs"] = [f for f in ht["funcs"] if f not in hidden_flaky]
        ht["run_regex"] = "^(%s)$" % "|".join(sorted(set(ht["funcs"]))) if ht["funcs"] else None
        ht["dropped_flaky"] = hidden_flaky
    ok = (base_status in ("compile_fail", "fail") and ht_t["pass"] and not hidden_always and bool(ht["funcs"]))
    report["ok"] = ok
    report["environment_failures"] = env_fail
    report["hidden_dropped_flaky"] = hidden_flaky
    report["reasons"] = ([] if base_status != "pass" else ["hidden tests pass at base"]) + \
                        ([] if ht_t["pass"] else ["hidden tests fail at target"]) + \
                        (["hidden test always failing at target: %s" % hidden_always] if hidden_always else []) + \
                        ([] if ht["funcs"] else ["no hidden tests left"])
    task["hidden_tests"]["base_status"] = base_status
    task["verify"] = {**task.get("verify", {}), **report, "status": "ok" if ok else "rejected",
                      "skip_regex": ("^(%s)$" % "|".join(skip_funcs)) if skip_funcs else None}
    write_json(os.path.join(task_dir, "task.json"), task)
    return report


# -------------------------------------------------------------------- lint --

IDENT_RE = re.compile(r"^\+\s*(?:func(?:\s*\([^)]*\))?\s+|type\s+|const\s+|var\s+)([A-Za-z_]\w+)", re.M)
FIELD_RE = re.compile(r"^\+\s+([A-Z]\w+)\s+[\[\]\*\w\.]+\s*(?:`[^`]*`)?\s*$", re.M)
FLAG_RE = re.compile(r'^\+.*?"(--?[a-z][a-z0-9-]{2,}|[a-z][a-z0-9_]{3,})"', re.M)


def lint_prompt(task_id: str) -> dict:
    from common import load_task
    task, task_dir = load_task(task_id)
    prompt_path = os.path.join(task_dir, "prompt.md")
    if not os.path.isfile(prompt_path):
        return {"ok": False, "reasons": ["prompt.md missing"]}
    prompt = read_text(prompt_path)
    patch = read_text(os.path.join(task_dir, "author.patch"))
    hidden_text = "\n".join(read_text(os.path.join(task_dir, "hidden", f)) for f in task["hidden_tests"]["files"])
    introduced = set(IDENT_RE.findall(patch)) | set(FIELD_RE.findall(patch))
    introduced = {i for i in introduced if len(i) >= 4 and i not in ("main", "init", "String", "Error", "Name", "Type")}
    visible = {i for i in introduced if re.search(r"\b%s\b" % re.escape(i), hidden_text)}
    leaks = sorted(i for i in (introduced - visible) if re.search(r"\b%s\b" % re.escape(i), prompt))
    path_leaks = sorted(p for p in task["author_patch"]["files_code"] if p in prompt)
    reasons: List[str] = []
    if leaks:
        reasons.append("identifiers introduced by the author and absent from the tests: %s" % leaks)
    if path_leaks:
        reasons.append("author code paths: %s" % path_leaks)
    for pr in task["prs"]:
        if str(pr["number"]) in prompt or (pr["title"] and pr["title"].lower() in prompt.lower()):
            reasons.append("PR number/title present")
    # the line budget covers the requirement, not the mechanical list of test paths:
    # count non-empty lines outside the "## Tests" section
    counted = []
    in_tests = False
    for l in prompt.splitlines():
        if l.startswith("## "):
            in_tests = l.strip().lower() == "## tests"
        if l.strip() and not in_tests:
            counted.append(l)
    n_lines = len(counted)
    if not (15 <= n_lines <= 45):
        reasons.append("prompt has %d non-empty lines outside the Tests section (want 15-45)" % n_lines)
    for f in task["hidden_tests"]["files"]:
        if f not in prompt:
            reasons.append("hidden test path not named: %s" % f)
    res = {"ok": not reasons, "reasons": reasons, "identifiers_checked": len(introduced), "visible_in_tests": len(visible)}
    task["prompt"] = {"sha256": sha256_text(prompt), "lines": n_lines, "lint": res}
    write_json(os.path.join(task_dir, "task.json"), task)
    return res


def vetbase(task_id: str) -> dict:
    """Record `go vet` findings at the base commit; scoring judges vet relative to them."""
    from common import load_task
    task, task_dir = load_task(task_id)
    repo_cfg = read_json(os.path.join(os.path.dirname(task_dir), "repo.json"))
    mirror = mirror_path(task["repo"])
    env = score_mod.go_env(repo_cfg, GOMOD_DIR, GOBUILD_DIR)
    d = _worktree(mirror, task["base_sha"], task_id + "-vetbase")
    r = run(["go", "vet", "./..."], cwd=d, env=env, timeout=1800)
    shutil.rmtree(d, ignore_errors=True)
    findings = score_mod.vet_findings(r.err)
    task.setdefault("verify", {})["vet_base_findings"] = findings
    task["verify"]["vet_base_rc"] = r.rc
    write_json(os.path.join(task_dir, "task.json"), task)
    return {"task_id": task_id, "rc": r.rc, "findings": findings}
