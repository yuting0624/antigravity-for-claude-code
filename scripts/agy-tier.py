#!/usr/bin/env python3
"""agy-tier: Predict optimal model tier ('pro', 'flash', or 'flash-lo') for delegation prompts.

Evolved via AlphaEvolve to maximize execution quality and prevent under-provisioning
while minimizing token expenditure on trivial or boilerplate tasks.

Usage:
    agy-tier [options] <prompt>
    cat prompt.txt | agy-tier [options]

Options:
    --meta <json>       Metadata dictionary (e.g. '{"files_changed": 15}')
    --json              Output prediction as JSON {"tier": "..."}
    -h, --help          Show this help message
"""
import sys
import json
import argparse


def predict_optimal_tier(prompt: str, metadata: dict | None = None) -> str:
    """Predict the cost-optimal execution tier ('pro', 'flash', or 'flash-lo').

    - 'pro': Hard reasoning, deep architecture, race conditions, low-level security,
             complex cryptography, distributed consensus, compiler type inference.
    - 'flash': Bulk scaffolding, boilerplate generation, test suites, web search,
               data pipelines, routine conversions, template migrations.
    - 'flash-lo': Trivial edits, single typo fixes, sorting imports, basic comments,
                  simple variable renames, version bumps, minor config updates.
    """
    if not isinstance(prompt, str):
        try:
            prompt = str(prompt)
        except Exception:
            prompt = ""

    p_lower = prompt.strip().lower().replace("-", " ")
    if not p_lower:
        return "flash-lo"

    # 1. Inspect metadata for explicit tier instructions or complexity cues
    if isinstance(metadata, dict):
        # Direct tier overrides
        for key in ("tier", "optimal_tier", "target_tier"):
            val = str(metadata.get(key, "")).strip().lower()
            if val in ("pro", "flash", "flash-lo"):
                return val

        # Priority / difficulty / category mapping
        mapping = {
            "high": "pro", "critical": "pro", "expert": "pro", "complex": "pro", "severe": "pro", "p0": "pro", "p1": "pro",
            "security": "pro", "cryptography": "pro", "concurrency": "pro", "architecture": "pro", "kernel": "pro", "distributed": "pro",
            "trivial": "flash-lo", "very low": "flash-lo", "minor": "flash-lo",
            "documentation": "flash-lo", "style": "flash-lo", "formatting": "flash-lo", "typo": "flash-lo"
        }
        for key in ("difficulty", "complexity", "priority", "severity", "urgency", "category"):
            val = str(metadata.get(key, "")).strip().lower()
            if val in mapping:
                return mapping[val]

        # Scale metrics (flattened)
        for key, threshold in (
            ("files_changed", 10), ("file_count", 10), ("num_files", 10), ("files", 10),
            ("lines_changed", 500), ("lines_of_code", 500), ("loc", 500)
        ):
            val = metadata.get(key)
            if val is not None:
                try:
                    if float(val) > threshold:
                        return "pro"
                except (ValueError, TypeError):
                    pass

    # 2. Pro Indicators: High reasoning, deep algorithmic complexity, subtle bugs
    pro_keywords = (
        "deadlock", "race condition", "concurrency", "mutex", "semaphore",
        "paxos", "consensus", "spanner", "serializability", "byzantine",
        "raft", "two phase commit", "2pc", "ebpf", "kernel module",
        "device driver", "syscall", "ioctl", "memory safety", "segfault",
        "segmentation fault", "use after free", "double free", "buffer overflow",
        "memory corruption", "cryptography", "cryptographic", "crypto",
        "zk snark", "zk stark", "homomorphic", "zero knowledge", "elliptic curve",
        "ecdsa", "aes gcm", "rsa encrypt", "rsa decrypt", "secure multi party",
        "multiparty computation", "compiler", "type inference", "polymorphic",
        "ast transformation", "architecture", "microservices", "saga pattern",
        "system design", "formal verification", "tla+", "alloy model",
        "thread safe", "multithreading bug", "lock free", "memory leak",
        "valgrind", "core dump", "cve", "vulnerability", "exploit", "canary",
        "reentrancy bug", "side channel"
    )
    if any(kw in p_lower for kw in pro_keywords):
        return "pro"

    # 3. Flash-Lo Indicators: Trivial / formatting / single token modifications
    flash_lo_keywords = (
        "typo", "spelling", "rename", "docstring", "comment",
        "bump version", "version field", "sort imports", "pep 8",
        "indentation", "trailing whitespace", "type annotation",
        "readme.md", "changelog.md", "gitignore", "editorconfig",
        "prettier", "eslint disable", "flake8", "autopep8",
        "black formatter", "yapf", "copyright notice", "license header",
        "grammar error", "wording", "phrasing", "disable test", "skip test",
        "unused import", "format code", "code formatting", "tabs to spaces"
    )
    if any(kw in p_lower for kw in flash_lo_keywords):
        return "flash-lo"

    # 4. Default to Flash (Bulk workhorse)
    return "flash"


def main():
    parser = argparse.ArgumentParser(description="Predict optimal model tier for delegation prompt.")
    parser.add_argument("prompt", nargs="?", default="", help="Delegation prompt string")
    parser.add_argument("--meta", default="", help="JSON string of metadata")
    parser.add_argument("--json", action="store_true", help="Output JSON format")
    args = parser.parse_args()

    prompt = args.prompt
    if not prompt and not sys.stdin.isatty():
        prompt = sys.stdin.read()

    metadata = None
    if args.meta:
        try:
            metadata = json.loads(args.meta)
        except Exception as e:
            sys.stderr.write(f"agy-tier: warning: invalid --meta JSON: {e}\n")

    tier = predict_optimal_tier(prompt, metadata)

    if args.json:
        print(json.dumps({"tier": tier, "prompt_chars": len(prompt)}))
    else:
        print(tier)


if __name__ == "__main__":
    main()
