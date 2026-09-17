#!/usr/bin/env python3
"""agy-condense: Condense noisy developer and agent outputs into a compact, high-signal digest.

Optimized via AlphaEvolve to preserve critical developer entities (file:line paths,
error codes, exit codes, status codes, stack traces, JSON logs) while strictly capping
length to ensure conductor context efficiency.

Usage:
    agy-condense [options] [file]
    cat noisy_output.log | agy-condense [options]

Options:
    --task <str>        Task context to prioritize relevant lines
    --max-chars <int>   Maximum character length of output (default: 1200)
    -h, --help          Show this help message
"""
import sys
import re
import json
import argparse

# Precompiled high-signal patterns
PATH_LINE_PATTERNS = [
    re.compile(r"\b([\w\-./\\]+\.[a-zA-Z0-9]+|[\w\-]+(?:/[\w\-]+)+):(\d+)(?::(\d+))?\b"),
    re.compile(r"File\s+['\"]([^'\"]+)['\"],\s+line\s+(\d+)"),
]

ERROR_CLASS_PATTERN = re.compile(
    r"\b([A-Z]\w*(?:Error|Exception|Failure|Fault|Crash|Panic|Violation))\b"
)

HIGH_SIGNAL_PATTERNS = [
    (re.compile(r"error\b|fail(?:ed|ure)?\b|exception\b|fatal\b|denied\b|critical\b|panic\b|abort\b|timeout\b|unhandled\b|unauthorized\b", re.IGNORECASE), 10),
    (re.compile(r"conflict|refused|undefined|invalid|nullpointer|nan|not found|permission", re.IGNORECASE), 8),
    (re.compile(r"\bexit\s*(?:code)?\s*(-?\d+)\b|\breturned\s+a\s+non-zero\b", re.IGNORECASE), 15),
    (re.compile(r"\bstatus\s*(?:code)?\s*(\d{3})\b|\bHTTP\s*(?:status\s*)?(4\d{2}|5\d{2})\b", re.IGNORECASE), 12),
    (re.compile(r"OOMKilled|CrashLoopBackOff|ErrImagePull|ImagePullBackOff", re.IGNORECASE), 15),
    (re.compile(r"\b(?:TS\d{4}|E\d{3,4}|F\d{3,4}|W\d{3,4}|C\d{3,4})\b"), 10),
    (re.compile(r"\b\d+\s*(?:failed|passed|errors|warnings|vulnerabilities|passed|skipped)\b", re.IGNORECASE), 20),
    (re.compile(r"built successfully|warning:|vulnerabilit(?:y|ies)", re.IGNORECASE), 8),
    (re.compile(r"エラー|失敗|警告|完了|例外"), 10),
]


def is_noisy_line(line: str) -> bool:
    if re.match(r"^[=\-_#*.~+:/\\|\s<>\[\]()]+$", line):
        return True
    line_lower = line.lower()
    if "%|" in line or "mib/s" in line_lower or "kb/s" in line_lower or "mb/s" in line_lower:
        return True
    if re.search(r"^\s*--->|transforming\s*\(\d+\)", line):
        return True
    if len(line) < 3:
        return True
    return False


def clean_line(raw_line: str) -> str:
    """Normalize line and unpack structured JSON log lines if present."""
    line = raw_line.strip()
    if not line:
        return ""

    # Unpack structured JSON log (e.g. Cloud Logging)
    if line.startswith("{") and line.endswith("}"):
        try:
            data = json.loads(line)
            parts = []
            for k in ["message", "msg", "log", "textPayload", "detail"]:
                if k in data and isinstance(data[k], str) and data[k].strip():
                    parts.append(data[k].strip())
                    break
            for k in ["error", "err", "exception", "stackTrace"]:
                if k in data and isinstance(data[k], str) and data[k].strip():
                    parts.append(data[k].strip())
                    break
            if parts:
                sev = data.get("severity") or data.get("level") or data.get("status")
                sev_prefix = f"[{sev}] " if sev else ""
                line = f"{sev_prefix}{' | '.join(parts)}"
        except Exception:
            pass

    # Strip decorative delimiters wrapped around text (e.g. === 1 failed, 2 passed ===)
    line = re.sub(r"^[=\-_#*.~]{3,}\s*", "", line)
    line = re.sub(r"\s*[=\-_#*.~]{3,}$", "", line)
    return line.strip()


def score_line(line: str, context_words: set) -> int:
    score = 0
    for pat in PATH_LINE_PATTERNS:
        if pat.search(line):
            score += 15

    if ERROR_CLASS_PATTERN.search(line):
        score += 12

    for pat, weight in HIGH_SIGNAL_PATTERNS:
        if pat.search(line):
            score += weight

    line_lower = line.lower()
    if context_words:
        matches = sum(1 for w in context_words if w in line_lower)
        score += matches * 12

    if len(line) > 300:
        score -= 15
    elif len(line) < 15:
        score -= 5

    return score


def condense(raw_output: str, task_context: str = "", max_chars: int = 1200) -> str:
    """Condense noisy output into a high-signal digest with DIGEST footer."""
    if not raw_output or not raw_output.strip():
        return "No output captured.\nDIGEST: Execution produced no output."

    # Strip ANSI escapes
    cleaned = re.sub(r"\x1B(?:\[[0-?]*[ -/]*[@-~]|[@-Z\\-_])", "", raw_output)
    raw_lines = [l.strip() for l in cleaned.splitlines() if l.strip()]

    if not raw_lines:
        return "Empty output.\nDIGEST: Execution returned only whitespace."

    # Extract context keywords
    stop_words = {"the", "and", "for", "with", "from", "this", "that", "not", "but", "run", "task"}
    context_words = {
        w.lower() for w in re.findall(r"\b\w{3,}\b", task_context)
        if w.lower() not in stop_words
    } if task_context else set()

    scored_lines = []
    seen = set()

    for idx, raw_l in enumerate(raw_lines):
        if is_noisy_line(raw_l):
            continue
        c_line = clean_line(raw_l)
        if not c_line or c_line in seen:
            continue

        s = score_line(c_line, context_words)
        if s > 0:
            seen.add(c_line)
            scored_lines.append((s, idx, c_line))

    # If no lines scored positively, take first few non-empty lines
    if not scored_lines:
        for idx, raw_l in enumerate(raw_lines[:5]):
            c_line = clean_line(raw_l)
            if c_line and c_line not in seen:
                seen.add(c_line)
                scored_lines.append((1, idx, c_line))

    # Sort by original appearance among high-scoring candidates, taking top 10
    top_candidates = sorted(scored_lines, key=lambda x: x[0], reverse=True)[:10]
    top_in_order = sorted(top_candidates, key=lambda x: x[1])

    bullets = [f"- {item[2][:160].strip()}" for item in top_in_order]

    # Find best summary line
    summary_candidates = [
        b[2:] for b in bullets
        if any(w in b.lower() for w in ["error", "fail", "success", "built", "warn", "exit", "失敗", "例外"])
    ]
    summary = summary_candidates[0][:120] if summary_candidates else bullets[0][2:][:120]

    body = "\n".join(bullets)
    final_digest = f"{body}\nDIGEST: {summary}"

    # Hard cap budget
    if len(final_digest) > max_chars:
        allowed = max(200, max_chars - len(summary) - 30)
        final_digest = f"{body[:allowed]}\n...\nDIGEST: {summary[:80]}"

    return final_digest


def main():
    parser = argparse.ArgumentParser(description="Condense noisy terminal output into a compact digest.")
    parser.add_argument("file", nargs="?", default="-", help="Input file (defaults to stdin)")
    parser.add_argument("--task", default="", help="Task context to prioritize relevant lines")
    parser.add_argument("--max-chars", type=int, default=1200, help="Maximum length of output (default: 1200)")
    args = parser.parse_args()

    if args.file == "-":
        raw = sys.stdin.read()
    else:
        try:
            with open(args.file, "r", encoding="utf-8", errors="replace") as f:
                raw = f.read()
        except OSError as e:
            sys.stderr.write(f"agy-condense: cannot read {args.file}: {e}\n")
            sys.exit(1)

    digest = condense(raw, task_context=args.task, max_chars=args.max_chars)
    sys.stdout.write(digest + "\n")


if __name__ == "__main__":
    main()
