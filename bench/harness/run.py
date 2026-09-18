"""One benchmark run: task × arm × rep. Prepares an isolated checkout and an isolated
CLAUDE_CONFIG_DIR, invokes `claude -p`, captures everything, then scores.

Isolation choices (each is a validity requirement, not a convenience):
  * the checkout is a `git clone --shared` of a local bare mirror, detached at base_sha,
    with the given test files committed on top and no remote — nothing to fetch;
  * CLAUDE_CONFIG_DIR is generated per run from bench/config/settings.template.json with
    only the Vertex/model env keys copied from the operator's settings — no user skills,
    plugins, memory, model or effort defaults leak in; the plugin arrives only through
    --plugin-dir;
  * GOPROXY=off, GOTOOLCHAIN=local, a pre-warmed shared module cache — no downloads;
  * the process runs in its own session so a wall-clock kill takes agy children with it.
"""
from __future__ import annotations

import json
import os
import shutil
import signal
import subprocess
import time
import uuid
from typing import Dict, List, Optional

import score as score_mod
from common import (CFG_DIR, CONFIG_DIR, GOBUILD_DIR, GOMOD_DIR, HOOKS_DIR, MIRRORS_DIR, POLICY_DIR,
                    PROMPTS_DIR, RESULTS_DIR, WORK_DIR, Prices, ensure_dirs, load_arms, load_task, now_iso,
                    read_json, read_text, run, sha256_text, write_json, write_text)

COPIED_ENV_KEYS = ("CLAUDE_CODE_USE_VERTEX", "ANTHROPIC_VERTEX_PROJECT_ID", "CLOUD_ML_REGION",
                   "GOOGLE_APPLICATION_CREDENTIALS", "ANTHROPIC_VERTEX_BASE_URL",
                   "ANTHROPIC_DEFAULT_OPUS_MODEL", "ANTHROPIC_DEFAULT_SONNET_MODEL",
                   "ANTHROPIC_DEFAULT_FABLE_MODEL", "ANTHROPIC_DEFAULT_HAIKU_MODEL", "NODE_EXTRA_CA_CERTS")
FIXED_ENV = {"BASH_DEFAULT_TIMEOUT_MS": "900000", "BASH_MAX_TIMEOUT_MS": "900000",
             "DISABLE_AUTOUPDATER": "1", "CLAUDE_CODE_ENABLE_TELEMETRY": "0"}
# The `claude` launcher follows auto-updates (2.1.270 became 2.1.272 between the pilot and
# the full run, from the operator's interactive sessions). CLAUDE_BIN pins one versioned
# binary for every run of a study; the path and its --version are recorded per run.
CLAUDE_BIN = os.environ.get("CLAUDE_BIN", "claude")
# agy self-updates too (1.2.2 -> 1.2.3 during the pilot). AGY_BIN_DIR, when set, is put
# first on PATH for the run so the wrapper resolves a pinned copy of the binary.
AGY_BIN_DIR = os.environ.get("AGY_BIN_DIR", "")


def mirror_path(repo: str) -> str:
    return os.path.join(MIRRORS_DIR, repo.replace("/", "__") + ".git")


def repo_config(task_dir: str) -> dict:
    return read_json(os.path.join(os.path.dirname(task_dir), "repo.json"))


def operator_env() -> Dict[str, str]:
    """Vertex/model keys from the operator's settings (values are not logged)."""
    src = os.path.join(os.path.expanduser("~/.claude"), "settings.json")
    env: Dict[str, str] = {}
    if os.path.isfile(src):
        for k, v in (read_json(src).get("env") or {}).items():
            if k in COPIED_ENV_KEYS or k.startswith("VERTEX_REGION_"):
                env[k] = str(v)
    for k in COPIED_ENV_KEYS:
        if k not in env and os.environ.get(k):
            env[k] = os.environ[k]
    env.update(FIXED_ENV)
    return env


def render_config_dir(run_key: str, plugin: bool, bash_timeout_ms: Optional[int] = None) -> str:
    cfg = os.path.join(CFG_DIR, run_key)
    if os.path.isdir(cfg):
        shutil.rmtree(cfg)
    os.makedirs(cfg)
    tmpl = read_json(os.path.join(CONFIG_DIR, "settings.template.json"))
    allow = [l.strip() for l in read_text(os.path.join(POLICY_DIR, "allow-common.txt")).splitlines() if l.strip()]
    if plugin:
        allow += [l.strip() for l in read_text(os.path.join(POLICY_DIR, "allow-plugin.txt")).splitlines() if l.strip()]
    tmpl.pop("_comment", None)
    tmpl["env"] = operator_env()
    if bash_timeout_ms:
        tmpl["env"]["BASH_DEFAULT_TIMEOUT_MS"] = str(bash_timeout_ms)
        tmpl["env"]["BASH_MAX_TIMEOUT_MS"] = str(bash_timeout_ms)
    tmpl["permissions"]["allow"] = allow
    text = json.dumps(tmpl, indent=2).replace("__HOOKS_DIR__", HOOKS_DIR)
    write_text(os.path.join(cfg, "settings.json"), text)
    # onboarding state so a headless run never sees a first-run dialog
    write_json(os.path.join(cfg, ".claude.json"), {"hasCompletedOnboarding": True, "projects": {}})
    return cfg


def prepare_checkout(task: dict, task_dir: str, run_key: str) -> str:
    mirror = mirror_path(task["repo"])
    if not os.path.isdir(mirror):
        raise RuntimeError("mirror missing: %s (run `bench.py curate mirror %s`)" % (mirror, task["repo"]))
    repo_dir = os.path.join(WORK_DIR, run_key)
    if os.path.isdir(repo_dir):
        shutil.rmtree(repo_dir)
    r = run(["git", "clone", "-q", "--shared", "--no-checkout", mirror, repo_dir], timeout=600)
    if not r.ok:
        raise RuntimeError("clone failed: %s" % r.err[-500:])
    r = run(["git", "checkout", "-q", "--detach", task["base_sha"]], cwd=repo_dir, timeout=600)
    if not r.ok:
        raise RuntimeError("checkout failed: %s" % r.err[-500:])
    run(["git", "remote", "remove", "origin"], cwd=repo_dir, timeout=60)
    for rel in task["hidden_tests"]["files"]:
        src = os.path.join(task_dir, "hidden", rel)
        dst = os.path.join(repo_dir, rel)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        shutil.copyfile(src, dst)
    run(["git", "add", "-f", "--"] + list(task["hidden_tests"]["files"]), cwd=repo_dir, timeout=60)
    r = run(["git", "-c", "user.name=bench", "-c", "user.email=bench@localhost", "commit", "-q",
             "--no-verify", "-m", "bench: given tests"], cwd=repo_dir, timeout=60)
    if not r.ok:
        raise RuntimeError("given-tests commit failed: %s" % r.err[-500:])
    return repo_dir


def register_agy_project(repo_dir: str) -> dict:
    """Make the checkout agy's project root. Measured on agy 1.2.2: in a directory agy has
    never seen, the agent runs in its last project root (here $HOME) or its scratch dir and
    goes looking for the repository; `--new-project` on a zero-turn `/model` probe registers
    the directory without spending a turn, after which `agy-delegate --dir .` works there."""
    agy_bin = os.path.join(AGY_BIN_DIR, "agy") if AGY_BIN_DIR else "agy"
    r = run([agy_bin, "--new-project", "--output-format", "json", "-p", "/model"], cwd=repo_dir, timeout=120, input_text="")
    return {"ok": r.ok, "out": r.out[:200], "err": r.err[-300:]}


def tool_versions(plugin_dir: Optional[str]) -> dict:
    agy_bin = os.path.join(AGY_BIN_DIR, "agy") if AGY_BIN_DIR else "agy"
    v = {"claude": run([CLAUDE_BIN, "--version"], timeout=60).out.strip(), "claude_bin": CLAUDE_BIN,
         "agy": run([agy_bin, "--version"], timeout=60).out.strip(), "agy_bin": agy_bin,
         "go": run(["go", "version"], timeout=60).out.strip(), "plugin": None, "plugin_sha": None}
    if plugin_dir:
        pj = os.path.join(plugin_dir, ".claude-plugin", "plugin.json")
        if os.path.isfile(pj):
            v["plugin"] = read_json(pj).get("version")
        v["plugin_sha"] = run(["git", "rev-parse", "--short", "HEAD"], cwd=plugin_dir, timeout=30).out.strip() or None
    return v


def build_prompt(task_dir: str, arm_cfg: dict) -> (str, dict):
    task_prompt = read_text(os.path.join(task_dir, "prompt.md"))
    appendix = ""
    if arm_cfg.get("appendix"):
        appendix = read_text(os.path.join(PROMPTS_DIR, arm_cfg["appendix"]))
    sent = task_prompt.rstrip() + ("\n\n" + appendix.strip() + "\n" if appendix else "\n")
    return sent, {"task_sha256": sha256_text(task_prompt), "appendix": arm_cfg.get("appendix"),
                  "appendix_sha256": sha256_text(appendix) if appendix else None, "sent_sha256": sha256_text(sent)}


def invoke_claude(repo_dir: str, cfg_dir: str, run_raw: str, prompt: str, arm_cfg: dict, arms: dict,
                  caps: dict, plugin_dir: Optional[str], task_repo_cfg: dict) -> dict:
    session_id = str(uuid.uuid4())
    allow_files = ["allow-common.txt"] + (["allow-plugin.txt"] if arm_cfg["plugin"] else [])
    allow: List[str] = []
    for f in allow_files:
        allow += [l.strip() for l in read_text(os.path.join(POLICY_DIR, f)).splitlines() if l.strip()]
    cmd = [CLAUDE_BIN, "-p", "--model", arm_cfg["conductor_alias"], "--effort", arms["effort"],
           "--output-format", "json", "--session-id", session_id, "--setting-sources", "user",
           "--permission-mode", "acceptEdits", "--permission-prompts", "none",
           "--max-turns", str(caps["max_turns"]), "--max-budget-usd", str(caps["max_budget_usd"]),
           "--allowedTools", ",".join(allow), "--disallowedTools", ",".join(arm_cfg["disallowed_tools"])]
    if arm_cfg["plugin"]:
        if not plugin_dir:
            raise RuntimeError("arm needs --plugin-dir")
        cmd += ["--plugin-dir", plugin_dir]
    env = dict(os.environ)
    env.update(score_mod.go_env(task_repo_cfg, GOMOD_DIR, GOBUILD_DIR))
    if AGY_BIN_DIR:
        env["PATH"] = AGY_BIN_DIR + os.pathsep + env.get("PATH", "")
    if arm_cfg["plugin"] and plugin_dir:
        # Claude Code puts a plugin's bin/ on the Bash tool's PATH itself, but in 3 of 9 hybrid
        # runs started within seconds of another session it did not (measured 2026-09-15:
        # the agent found no agy-delegate and stopped). The plugin's own bin/ goes on PATH
        # here so the arm's only write path is always present.
        env["PATH"] = os.path.join(plugin_dir, "bin") + os.pathsep + env["PATH"]
    if arm_cfg.get("policy") == "strict":
        env["BENCH_POLICY"] = "strict"
    env.update({"CLAUDE_CONFIG_DIR": cfg_dir, "AGY_USAGE_LOG": os.path.join(run_raw, "agy_usage.log"),
                "BENCH_TRACE_LOG": os.path.join(run_raw, "tool_trace.jsonl"), "BENCH_REPO_DIR": repo_dir,
                "BENCH_PLUGIN": "1" if arm_cfg["plugin"] else "0"})
    # never let the operator's shell defaults steer the conductor
    for k in ("CLAUDE_CODE_EFFORT", "ANTHROPIC_MODEL", "CLAUDE_CODE_MAX_OUTPUT_TOKENS"):
        env.pop(k, None)
    write_text(os.path.join(run_raw, "command.txt"), " ".join(_q(c) for c in cmd) + "\n")
    started = time.time()
    mono0 = time.monotonic()  # does not advance while the machine sleeps; wall time does
    killed = False
    with open(os.path.join(run_raw, "result.json"), "w", encoding="utf-8") as out_fh, \
            open(os.path.join(run_raw, "claude.stderr"), "w", encoding="utf-8") as err_fh:
        p = subprocess.Popen(cmd, cwd=repo_dir, env=env, stdin=subprocess.PIPE, stdout=out_fh, stderr=err_fh,
                             text=True, start_new_session=True)
        # the wall cap counts ACTIVE time (monotonic clock): a laptop asleep for an hour must
        # not turn into a killed run. Sleep itself is still recorded as suspended_s below.
        try:
            p.stdin.write(prompt); p.stdin.close()
        except Exception:  # noqa: BLE001
            pass
        while True:
            try:
                p.wait(timeout=15)
                break
            except subprocess.TimeoutExpired:
                if time.monotonic() - mono0 > caps["wall_s"]:
                    killed = True
                    try:
                        os.killpg(p.pid, signal.SIGTERM)
                        p.wait(timeout=60)
                    except Exception:  # noqa: BLE001
                        try:
                            os.killpg(p.pid, signal.SIGKILL)
                        except Exception:  # noqa: BLE001
                            pass
                    break
    wall = time.time() - started
    mono = time.monotonic() - mono0
    # a laptop lid closed mid-run: wall clock runs on, the monotonic clock does not, and the
    # in-flight API call dies on wake. Recorded so the scheduler retries instead of scoring it.
    suspended = round(max(0.0, wall - mono), 1)
    return {"session_id": session_id, "rc": p.returncode, "killed_wall": killed,
            "agent_wall_s": round(wall, 1), "agent_active_s": round(mono, 1),
            "suspended_s": suspended if suspended > 30 else 0.0, "command": cmd}


def _q(s: str) -> str:
    return s if all(c.isalnum() or c in "-_./:=,*()[]" for c in s) else "'" + s.replace("'", "'\\''") + "'"


def collect_transcripts(cfg_dir: str, session_id: str, run_raw: str) -> List[str]:
    import glob
    dst_dir = os.path.join(run_raw, "transcripts")
    os.makedirs(dst_dir, exist_ok=True)
    copied: List[str] = []
    mains = glob.glob(os.path.join(cfg_dir, "projects", "*", session_id + ".jsonl"))
    for i, m in enumerate(sorted(mains)):
        dst = os.path.join(dst_dir, "main%s.jsonl" % ("" if i == 0 else i))
        shutil.copyfile(m, dst)
        copied.append(dst)
    subs = glob.glob(os.path.join(cfg_dir, "projects", "*", session_id, "**", "*.jsonl"), recursive=True)
    for i, s in enumerate(sorted(subs)):
        dst = os.path.join(dst_dir, "sub%d.jsonl" % i)
        shutil.copyfile(s, dst)
        copied.append(dst)
    return copied


def quota_probe(run_raw: str, name: str) -> None:
    agy_bin = os.path.join(AGY_BIN_DIR, "agy") if AGY_BIN_DIR else "agy"
    r = run([agy_bin, "--output-format", "json", "-p", "/quota"], timeout=60, input_text="")
    write_text(os.path.join(run_raw, "quota_%s.json" % name), r.out or r.err)


def on_ac_power() -> bool:
    r = run(["pmset", "-g", "batt"], timeout=20)
    return "AC Power" in r.out or r.rc != 0  # unknown -> do not block


def wait_for_ac(max_s: float = 5.5 * 3600) -> float:
    """Block while the machine runs on battery. Measured 2026-09-16: every run death of
    this study happened at a wake from a sleep entered on battery (lid closed); a 2 h
    hybrid attempt died that way at $24. New runs start only on mains power; running ones
    are not touched. Returns the seconds waited."""
    t0 = time.time()
    while not on_ac_power() and time.time() - t0 < max_s:
        time.sleep(60)
    return round(time.time() - t0, 1)


def run_once(task_id: str, arm: str, rep: int, run_id: str, plugin_dir: Optional[str] = None,
             lane: str = "A", attempt: int = 1, keep_checkout: bool = False,
             cap_overrides: Optional[dict] = None) -> dict:
    ensure_dirs()
    arms = load_arms()
    arm_cfg = arms["arms"][arm]
    task, task_dir = load_task(task_id)
    repo_cfg = repo_config(task_dir)
    caps = dict(arms["caps"][task["size_class"]])
    if cap_overrides:  # plumbing checks only; recorded in meta/caps so a capped run is never mistaken for a real one
        caps.update({k: v for k, v in cap_overrides.items() if v is not None})
        caps["overridden"] = True
    run_key = "%s__%s__r%d" % (task_id, arm, rep)
    run_dir = os.path.join(RESULTS_DIR, run_id, "runs", run_key)
    if attempt > 1:
        run_dir = os.path.join(run_dir, "attempts", str(attempt))
    raw = os.path.join(run_dir, "raw")
    if os.path.isdir(run_dir):
        shutil.rmtree(run_dir)
    os.makedirs(raw)
    stop = os.path.join(RESULTS_DIR, run_id, os.environ.get("BENCH_STOP_FILE", "STOP"))
    if os.path.exists(stop):
        raise SystemExit("STOP file present: %s" % stop)

    waited_for_ac = wait_for_ac()
    prompt, prompt_meta = build_prompt(task_dir, arm_cfg)
    write_text(os.path.join(raw, "prompt_sent.md"), prompt)
    repo_dir = prepare_checkout(task, task_dir, run_key)
    agy_project = register_agy_project(repo_dir) if arm_cfg["plugin"] else None
    cfg_dir = render_config_dir(run_key, arm_cfg["plugin"], arm_cfg.get("bash_timeout_ms"))
    versions = tool_versions(plugin_dir if arm_cfg["plugin"] else None)
    meta = {"run_id": run_id, "run_key": run_key, "task_id": task_id, "arm": arm, "rep": rep, "attempt": attempt,
            "lane": lane, "started_at": now_iso(), "versions": versions, "conductor_alias": arm_cfg["conductor_alias"],
            "effort": arms["effort"], "executor": {"default_tier": "flash", "agy_timeout": arms["agy_timeout"]},
            "caps": caps, "prompt": prompt_meta, "repo_dir": repo_dir, "cfg_dir": cfg_dir,
            "agy_project": agy_project, "waited_for_ac_s": waited_for_ac}
    write_json(os.path.join(raw, "meta.json"), meta)
    if arm_cfg["plugin"]:
        quota_probe(raw, "before")
    inv = invoke_claude(repo_dir, cfg_dir, raw, prompt, arm_cfg, arms, caps, plugin_dir, repo_cfg)
    if arm_cfg["plugin"]:
        quota_probe(raw, "after")
    meta.update({"ended_at": now_iso(), "agent_wall_s": inv["agent_wall_s"], "agent_active_s": inv["agent_active_s"],
                 "suspended_s": inv["suspended_s"], "claude_rc": inv["rc"],
                 "killed_wall": inv["killed_wall"], "session_id": inv["session_id"]})
    meta["transcripts"] = collect_transcripts(cfg_dir, inv["session_id"], raw)
    write_json(os.path.join(raw, "meta.json"), meta)

    prices = Prices()
    rec = score_mod.score_run(run_dir, repo_dir, task, task_dir, repo_cfg, arm, prices, GOMOD_DIR, GOBUILD_DIR, meta)
    rec["prices_lock_sha256"] = prices.sha256
    # the scheduler's verdict is computed here, in the per-item interpreter, so a policy
    # change applies at the next item without restarting the lanes
    import schedule as sched
    rec["scheduler_class"] = sched.classify(rec, None)
    write_json(os.path.join(run_dir, "run.json"), rec)
    if not keep_checkout:
        shutil.rmtree(repo_dir, ignore_errors=True)
        shutil.rmtree(cfg_dir, ignore_errors=True)
    return rec
