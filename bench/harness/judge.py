"""Blinded quality review of every candidate patch by two judge families.

Per task the candidates are: every run's code-only diff, the author's non-test patch,
and an empty patch (floor anchor). Ids are shuffled with a seed; the id -> source map is
written to judge/blind-map.json and read only by analyze.py. Each candidate is scored
alone (no pairwise position bias), on six axes 1–5, JSON only.

Judges:
  claude — `claude -p --model fable --tools "" --json-schema prompts/judge.schema.json`
           in an isolated CLAUDE_CONFIG_DIR (Vertex env only, no hooks, no plugins);
  gemini — `bin/agy-delegate --tier pro -` (Gemini 3.1 Pro through the plugin wrapper,
           without --digest: the digest contract fights the JSON-only contract).
"""
from __future__ import annotations

import glob
import hashlib
import json
import os
import random
import re
import shutil
import subprocess
import time
from typing import Dict, List, Optional, Tuple

import run as run_mod
from common import (BENCH_DIR, CFG_DIR, PROMPTS_DIR, RESULTS_DIR, TASKS_DIR, classify_path, load_task, now_iso,
                    read_json, read_text, run, sha256_text, write_json, write_text)

AXES = ("consistency", "edge_cases", "scope", "readability", "robustness", "maintainability")
FLAGS = {"unrelated_changes", "incomplete", "suspicious_test_workaround", "generated_code_smell", "empty_diff"}
CONTEXT_CAP = 60_000


# ------------------------------------------------------------- candidates ---

def strip_tests_from_patch(patch: str) -> str:
    """Keep only non-test file hunks; drop `index` lines so hashes do not identify a source."""
    out: List[str] = []
    keep = False
    for line in patch.splitlines():
        if line.startswith("diff --git "):
            m = re.match(r"diff --git a/(.*?) b/(.*)$", line)
            path = m.group(2) if m else ""
            keep = classify_path(path) in ("code", "gomod", "other", "doc")
        if not keep:
            continue
        if line.startswith("index "):
            continue
        out.append(line)
    return "\n".join(out) + ("\n" if out else "")


def touched_files(patch: str) -> List[Tuple[str, bool]]:
    """[(path, is_new)] for every file in a diff."""
    files: List[Tuple[str, bool]] = []
    cur = None
    for line in patch.splitlines():
        if line.startswith("diff --git "):
            m = re.match(r"diff --git a/(.*?) b/(.*)$", line)
            cur = m.group(2) if m else None
            if cur:
                files.append((cur, False))
        elif line.startswith("new file mode") and files and files[-1][0] == cur:
            files[-1] = (cur, True)
    return files


def build_candidates(run_id: str, task_id: str, seed: int) -> dict:
    task, task_dir = load_task(task_id)
    runs_dir = os.path.join(RESULTS_DIR, run_id, "runs")
    cands: Dict[str, dict] = {}
    for rd in sorted(glob.glob(os.path.join(runs_dir, "%s__*" % task_id))):
        rj = os.path.join(rd, "run.json")
        pd = os.path.join(rd, "patch.diff")
        if not (os.path.isfile(rj) and os.path.isfile(pd)):
            continue
        rec = read_json(rj)
        if rec.get("status") not in (None, "ok"):
            continue
        cands["run:" + os.path.basename(rd)] = {"diff": strip_tests_from_patch(read_text(pd)), "source": "run:" + os.path.basename(rd)}
    cands["author"] = {"diff": strip_tests_from_patch(read_text(os.path.join(task_dir, "author.patch"))), "source": "author"}
    cands["null"] = {"diff": "", "source": "null"}
    rng = random.Random("%d:%s" % (seed, task_id))
    keys = sorted(cands)
    rng.shuffle(keys)
    blind: Dict[str, dict] = {}
    for k in keys:
        cid = "c-" + hashlib.sha256(("%d:%s:%s" % (seed, task_id, k)).encode()).hexdigest()[:6]
        blind[cid] = {"task_id": task_id, "source": cands[k]["source"], "diff_sha256": sha256_text(cands[k]["diff"])}
        cands[k]["cid"] = cid
    return {"task": task, "task_dir": task_dir, "candidates": {c["cid"]: c for c in cands.values()}, "blind": blind}


# ----------------------------------------------------------- context pack ---

def context_pack(task: dict, patch: str) -> str:
    mirror = run_mod.mirror_path(task["repo"])
    base = task["base_sha"]
    parts: List[str] = []
    for path, is_new in touched_files(patch):
        if classify_path(path) != "code":
            continue
        if not is_new:
            body = run(["git", "-C", mirror, "show", "%s:%s" % (base, path)], timeout=60).out
            if body:
                head = "\n".join(body.splitlines()[:300])
                parts.append("### %s (base, first 300 lines)\n```go\n%s\n```" % (path, head))
                continue
        pkg = os.path.dirname(path)
        listing = run(["git", "-C", mirror, "ls-tree", "--name-only", "-l", "%s:%s" % (base, pkg) if pkg else base], timeout=60).out
        best, best_size = None, -1
        for line in run(["git", "-C", mirror, "ls-tree", "-l", "%s:%s" % (base, pkg) if pkg else base], timeout=60).out.splitlines():
            cols = line.split()
            if len(cols) >= 5 and cols[4].endswith(".go") and not cols[4].endswith("_test.go"):
                try:
                    size = int(cols[3])
                except ValueError:
                    continue
                if size > best_size:
                    best, best_size = cols[4], size
        if best:
            rel = (pkg + "/" if pkg else "") + best
            body = run(["git", "-C", mirror, "show", "%s:%s" % (base, rel)], timeout=60).out
            head = "\n".join(body.splitlines()[:200])
            parts.append("### %s is new; convention reference %s (base, first 200 lines)\n```go\n%s\n```" % (path, rel, head))
        else:
            parts.append("### %s is new; its package does not exist at the base commit" % path)
        _ = listing
    text = "\n\n".join(parts)
    if len(text) > CONTEXT_CAP:
        text = text[:CONTEXT_CAP] + "\n\n[context truncated at %d characters]" % CONTEXT_CAP
    return text or "(no code files touched)"


def judge_prompt(task_dir: str, task: dict, diff: str) -> str:
    tmpl = read_text(os.path.join(PROMPTS_DIR, "judge.md"))
    prompt = read_text(os.path.join(task_dir, "prompt.md"))
    return (tmpl.replace("{{prompt}}", prompt.strip())
                .replace("{{context_pack}}", context_pack(task, diff))
                .replace("{{diff}}", diff.strip() if diff.strip() else "(empty diff)"))


# ---------------------------------------------------------------- judges ----

def _judge_cfg_dir() -> str:
    cfg = os.path.join(CFG_DIR, "judge")
    if not os.path.isdir(cfg):
        os.makedirs(cfg)
        write_json(os.path.join(cfg, "settings.json"), {"env": run_mod.operator_env(), "permissions": {"allow": [], "deny": []}})
        write_json(os.path.join(cfg, ".claude.json"), {"hasCompletedOnboarding": True, "projects": {}})
    return cfg


def judge_claude(prompt: str, model_alias: str = "fable", budget: float = 4.0) -> dict:
    cfg = _judge_cfg_dir()
    schema = read_text(os.path.join(PROMPTS_DIR, "judge.schema.json"))
    cmd = [run_mod.CLAUDE_BIN, "-p", "--model", model_alias, "--tools", "", "--output-format", "json", "--json-schema", schema,
           "--max-turns", "3", "--max-budget-usd", str(budget), "--no-session-persistence", "--setting-sources", "user",
           "--disallowedTools", "WebFetch,WebSearch,Bash,Edit,Write,Read,Glob,Grep,Agent"]
    env = {"CLAUDE_CONFIG_DIR": cfg}
    t0 = time.time()
    r = run(cmd, env=env, timeout=600, input_text=prompt)
    rec = {"judge": "claude", "wall_s": round(time.time() - t0, 1), "rc": r.rc, "raw": r.out[-20000:], "stderr": r.err[-2000:],
           "cost_usd": None, "model_id": None, "text": ""}
    try:
        d = json.loads(r.out)
        rec["cost_usd"] = d.get("total_cost_usd")
        rec["model_id"] = ",".join(sorted((d.get("modelUsage") or {}).keys()))
        so = d.get("structured_output")
        rec["text"] = json.dumps(so) if isinstance(so, dict) else str(d.get("result") or "")
        rec["subtype"] = d.get("subtype")
    except Exception as e:  # noqa: BLE001
        rec["text"] = r.out
        rec["parse_note"] = "result not JSON: %s" % e
    return rec


def judge_gemini(prompt: str, plugin_dir: str, log_path: str) -> dict:
    wrapper = os.path.join(plugin_dir, "bin", "agy-delegate")
    t0 = time.time()
    env = {"AGY_USAGE_LOG": log_path}
    if run_mod.AGY_BIN_DIR:
        env["PATH"] = run_mod.AGY_BIN_DIR + os.pathsep + os.environ.get("PATH", "")
    r = run([wrapper, "--tier", "pro", "--timeout", "5m", "-"], env=env, timeout=420, input_text=prompt)
    rec = {"judge": "gemini", "wall_s": round(time.time() - t0, 1), "rc": r.rc, "raw": r.out[-20000:], "stderr": r.err[-2000:],
           "cost_usd": None, "model_id": None, "text": r.out}
    m = re.search(r"AGY_USAGE (\{.*\})", r.err)
    if m:
        try:
            u = json.loads(m.group(1))
            rec["model_id"] = u.get("model")
            rec["usage"] = u.get("usage")
            from common import Prices
            key, _ = Prices().gemini_key(u.get("model") or "", u.get("tier") or "pro")
            rec["cost_usd"], rec["cost_flags"] = Prices().price_gemini(u.get("usage") or {}, key)
            rec["cost_usd"] = round(rec["cost_usd"], 6)
        except Exception:  # noqa: BLE001
            pass
    return rec


def parse_scores(text: str) -> Tuple[Optional[dict], str]:
    """First balanced JSON object with the expected shape; tolerant of fences and prose."""
    if not text:
        return None, "empty response"
    start = text.find("{")
    while start != -1:
        depth = 0
        in_str = False
        esc = False
        for i in range(start, len(text)):
            c = text[i]
            if in_str:
                if esc:
                    esc = False
                elif c == "\\":
                    esc = True
                elif c == '"':
                    in_str = False
                continue
            if c == '"':
                in_str = True
            elif c == "{":
                depth += 1
            elif c == "}":
                depth -= 1
                if depth == 0:
                    chunk = text[start:i + 1]
                    try:
                        obj = json.loads(chunk)
                    except Exception:  # noqa: BLE001
                        break
                    ok, why = _validate(obj)
                    if ok:
                        return obj, ""
                    return None, why
        start = text.find("{", start + 1)
    return None, "no JSON object found"


def _validate(obj) -> Tuple[bool, str]:
    if not isinstance(obj, dict):
        return False, "not an object"
    sc = obj.get("scores")
    if not isinstance(sc, dict):
        return False, "scores missing"
    for a in AXES:
        v = sc.get(a)
        if not isinstance(v, int) or isinstance(v, bool) or not 1 <= v <= 5:
            return False, "axis %s invalid: %r" % (a, v)
    ra = obj.get("rationale")
    if not isinstance(ra, dict) or any(a not in ra for a in AXES):
        return False, "rationale missing an axis"
    if any(len(str(ra[a])) > 300 for a in AXES):
        return False, "rationale too long"
    fl = obj.get("flags", [])
    if not isinstance(fl, list) or any(f not in FLAGS for f in fl):
        return False, "bad flags"
    return True, ""


# ------------------------------------------------------------------ main ----

def judge_task(run_id: str, task_id: str, judges: List[str], plugin_dir: Optional[str], seed: int,
               force: bool = False) -> List[dict]:
    built = build_candidates(run_id, task_id, seed)
    jdir = os.path.join(RESULTS_DIR, run_id, "judge")
    os.makedirs(os.path.join(jdir, task_id), exist_ok=True)
    os.makedirs(os.path.join(jdir, "raw", task_id), exist_ok=True)
    bm_path = os.path.join(jdir, "blind-map.json")
    bm = read_json(bm_path) if os.path.isfile(bm_path) else {"seed": seed, "candidates": {}}
    bm["candidates"].update(built["blind"])
    write_json(bm_path, bm)
    out: List[dict] = []
    for cid, cand in sorted(built["candidates"].items()):
        prompt = judge_prompt(built["task_dir"], built["task"], cand["diff"])
        write_text(os.path.join(jdir, "raw", task_id, "%s.prompt.md" % cid), prompt)
        for judge in judges:
            rec_path = os.path.join(jdir, task_id, "%s__%s.json" % (cid, judge))
            if os.path.isfile(rec_path) and not force:
                out.append(read_json(rec_path))
                continue
            rec = None
            for attempt in (1, 2):
                if judge == "claude":
                    raw = judge_claude(prompt)
                elif judge == "gemini":
                    if not plugin_dir:
                        raise RuntimeError("gemini judge needs --plugin-dir")
                    raw = judge_gemini(prompt, plugin_dir, os.path.join(jdir, "raw", "agy_usage.log"))
                else:
                    raise ValueError(judge)
                write_text(os.path.join(jdir, "raw", task_id, "%s__%s.attempt%d.txt" % (cid, judge, attempt)), raw.get("raw", ""))
                scores, why = parse_scores(raw.get("text", ""))
                rec = {"schema": "bench.judge/1", "run_id": run_id, "task_id": task_id, "candidate_id": cid, "judge": judge,
                       "judge_model_id": raw.get("model_id"), "attempt": attempt, "judged_at": now_iso(),
                       "status": "ok" if scores else ("error" if raw.get("rc") not in (0, None) else "format_error"),
                       "format_error": why, "prompt_sha256": sha256_text(prompt), "wall_s": raw.get("wall_s"),
                       "cost_usd": raw.get("cost_usd"), "usage": raw.get("usage"), "rc": raw.get("rc")}
                if scores:
                    rec["scores"] = scores["scores"]
                    rec["mean"] = round(sum(scores["scores"][a] for a in AXES) / len(AXES), 3)
                    rec["rationale"] = scores["rationale"]
                    rec["flags"] = scores.get("flags", [])
                    break
            write_json(rec_path, rec)
            out.append(rec)
    return out
