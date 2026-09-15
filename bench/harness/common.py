"""Shared paths, JSON helpers, subprocess wrapper and the two price decks.

Everything under ~/.cache/agy-bench (override with AGY_BENCH_HOME) is scratch: git
mirrors, worktrees, per-run CLAUDE_CONFIG_DIRs, the shared Go module/build caches.
Everything under bench/ in the repo is the record: tasks, results, protocol.
"""
from __future__ import annotations

import datetime as _dt
import hashlib
import json
import os
import subprocess
import time
from dataclasses import dataclass
from typing import Dict, List, Optional, Tuple

BENCH_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REPO_DIR = os.path.dirname(BENCH_DIR)
TASKS_DIR = os.path.join(BENCH_DIR, "tasks")
RESULTS_DIR = os.environ.get("AGY_BENCH_RESULTS_DIR") or os.path.join(BENCH_DIR, "results")
PROMPTS_DIR = os.path.join(BENCH_DIR, "prompts")
POLICY_DIR = os.path.join(BENCH_DIR, "policy")
HOOKS_DIR = os.path.join(BENCH_DIR, "hooks")
CONFIG_DIR = os.path.join(BENCH_DIR, "config")
ARMS_PATH = os.path.join(BENCH_DIR, "arms.json")
PRICES_LOCK = os.path.join(BENCH_DIR, "prices.lock.json")

BENCH_HOME = os.path.expanduser(os.environ.get("AGY_BENCH_HOME", "~/.cache/agy-bench"))
MIRRORS_DIR = os.path.join(BENCH_HOME, "mirrors")
WORK_DIR = os.path.join(BENCH_HOME, "work")
CFG_DIR = os.path.join(BENCH_HOME, "cfg")
GOMOD_DIR = os.path.join(BENCH_HOME, "gomod")
GOBUILD_DIR = os.path.join(BENCH_HOME, "gobuild")

AGY_HEADS = ("agy-delegate", "agy-job", "agy-trace")
TEST_FILE_MARKERS = ("_test.go",)
TEST_DIR_MARKERS = ("testdata/", "/testdata/", "acceptance/", "pkg/integration/tests/")


# ------------------------------------------------------------------ io -----

def read_json(path: str):
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


def write_json(path: str, obj) -> None:
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(obj, fh, indent=2, ensure_ascii=False, sort_keys=False)
        fh.write("\n")
    os.replace(tmp, path)


def read_text(path: str) -> str:
    with open(path, encoding="utf-8") as fh:
        return fh.read()


def write_text(path: str, text: str) -> None:
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(text)


def sha256_file(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def sha256_text(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def now_iso() -> str:
    return _dt.datetime.now(_dt.timezone.utc).replace(microsecond=0).isoformat()


def ensure_dirs() -> None:
    for d in (MIRRORS_DIR, WORK_DIR, CFG_DIR, GOMOD_DIR, GOBUILD_DIR, RESULTS_DIR):
        os.makedirs(d, exist_ok=True)


# ----------------------------------------------------------- subprocess ----

@dataclass
class Result:
    rc: int
    out: str
    err: str
    timed_out: bool
    seconds: float

    @property
    def ok(self) -> bool:
        return self.rc == 0 and not self.timed_out


def run(cmd: List[str], cwd: Optional[str] = None, env: Optional[Dict[str, str]] = None,
        timeout: Optional[float] = None, input_text: Optional[str] = None,
        stdout_path: Optional[str] = None) -> Result:
    """Run a command; never raises on non-zero exit or timeout (both are data)."""
    t0 = time.time()
    full_env = dict(os.environ)
    if env:
        full_env.update(env)
    out_fh = open(stdout_path, "w", encoding="utf-8") if stdout_path else None
    try:
        p = subprocess.run(cmd, cwd=cwd, env=full_env, input=input_text,
                           stdout=out_fh or subprocess.PIPE, stderr=subprocess.PIPE,
                           text=True, timeout=timeout, errors="replace")
        return Result(p.returncode, "" if out_fh else (p.stdout or ""), p.stderr or "",
                      False, time.time() - t0)
    except subprocess.TimeoutExpired as e:
        out = "" if out_fh else ((e.stdout or b"").decode("utf-8", "replace") if isinstance(e.stdout, bytes) else (e.stdout or ""))
        err = (e.stderr or b"").decode("utf-8", "replace") if isinstance(e.stderr, bytes) else (e.stderr or "")
        return Result(124, out, err, True, time.time() - t0)
    finally:
        if out_fh:
            out_fh.close()


# ---------------------------------------------------------------- prices ---

class Prices:
    """The two price decks, read from bench/prices.lock.json (never prices.json directly)."""

    def __init__(self, path: str = PRICES_LOCK):
        self.path = path
        self.data = read_json(path)
        self.sha256 = sha256_file(path)
        self.cache_write_mult = float(self.data.get("cache_write_mult", 1.25))
        self.cache_read_mult = float(self.data.get("cache_read_mult", 0.1))

    # Claude ---------------------------------------------------------------
    def claude_key(self, model_id: str) -> Optional[str]:
        m = (model_id or "").lower()
        if "opus" in m:
            return "claude_opus"
        if "sonnet" in m:
            return "claude_sonnet"
        if "fable" in m and "claude_fable" in self.data:
            return "claude_fable"
        return None

    def price_claude(self, model_id: str, input_tokens: int, output_tokens: int,
                     cache_creation: int, cache_read: int) -> Tuple[Optional[float], List[str]]:
        key = self.claude_key(model_id)
        if not key:
            return None, ["no_claude_rate_for:%s" % model_id]
        d = self.data[key]
        inp, out = float(d["in"]), float(d["out"])
        usd = (input_tokens * inp + output_tokens * out
               + cache_creation * inp * self.cache_write_mult
               + cache_read * inp * self.cache_read_mult) / 1e6
        return usd, []

    # Gemini ---------------------------------------------------------------
    def gemini_key(self, model_name: str = "", tier: str = "") -> Tuple[Optional[str], List[str]]:
        m = (model_name or "").lower()
        if "gemini" in m:
            if "pro" in m:
                return "gemini_pro", []
            for ver, key in (("3.8", "gemini_flash_38"), ("3.7", "gemini_flash_37"),
                             ("3.6", "gemini_flash_36"), ("3.5", "gemini_flash_35")):
                if ver in m and key in self.data:
                    return key, []
            if "flash" in m:
                return "gemini_flash", ["flash_version_unrecognised:%s" % model_name]
        if tier in ("flash", "flash-lo"):
            return "gemini_flash", []
        if tier == "pro":
            return "gemini_pro", []
        return None, []

    def price_gemini(self, usage: Dict[str, int], key: Optional[str]) -> Tuple[float, List[str]]:
        """input×in + output×out + cache_read×cached_in — three separate terms, never a subtraction."""
        flags: List[str] = []
        if key is None or key not in self.data:
            key = "gemini_pro"
            flags.append("unknown_tier_priced_as_pro")
        d = self.data[key]
        inp, out = float(d["in"]), float(d["out"])
        cached = d.get("cached_in")
        if cached is None:
            cached = inp
            flags.append("no_cached_rate_for:%s" % key)
        usd = (int(usage.get("input", 0)) * inp + int(usage.get("output", 0)) * out
               + int(usage.get("cache_read", 0)) * float(cached)) / 1e6
        return usd, flags


# ------------------------------------------------------------------ arms ---

def load_arms() -> dict:
    return read_json(ARMS_PATH)


def caps_for(size_class: str, arms: Optional[dict] = None) -> dict:
    arms = arms or load_arms()
    return arms["caps"][size_class]


def size_class(nontest_added: int) -> str:
    if nontest_added < 100:
        return "small"
    if nontest_added <= 600:
        return "medium"
    return "large"


# ----------------------------------------------------------------- tasks ---

def find_task_dir(task_id: str) -> str:
    for repo in sorted(os.listdir(TASKS_DIR)) if os.path.isdir(TASKS_DIR) else []:
        cand = os.path.join(TASKS_DIR, repo, task_id)
        if os.path.isfile(os.path.join(cand, "task.json")):
            return cand
    raise FileNotFoundError("no task %s under %s" % (task_id, TASKS_DIR))


def load_task(task_id: str) -> Tuple[dict, str]:
    d = find_task_dir(task_id)
    return read_json(os.path.join(d, "task.json")), d


def is_test_path(path: str) -> bool:
    p = path.replace("\\", "/")
    if p.endswith(TEST_FILE_MARKERS):
        return True
    return any(m in p or p.startswith(m.lstrip("/")) for m in TEST_DIR_MARKERS)


def classify_path(path: str) -> str:
    p = path.replace("\\", "/")
    if p in ("go.mod", "go.sum") or p.endswith("/go.mod") or p.endswith("/go.sum"):
        return "gomod"
    if is_test_path(p):
        return "test"
    if p.endswith(".go"):
        return "code"
    if p.endswith((".md", ".txt", ".rst")):
        return "doc"
    return "other"
