#!/usr/bin/env python3
"""agy-log-cluster: Cluster noisy Cloud Run & K8s logs and extract root cause candidates.

Optimized via AlphaEvolve (champion prog-attentive-unicorn, score 0.909161) to compress
massive raw log streams (>200 KB) into a compact, high-signal digest (<4,000 characters),
separating primary trigger events from cascading secondary failures (e.g. repeated 500s,
probe timeouts, reconnect loops).

Usage:
    agy-log-cluster [options] [file]
    cat incident.json | agy-log-cluster [options]
    gcloud logging read ... --format=json | agy-log-cluster [options]

Options:
    --max-chars <int>      Maximum character length of output digest (default: 4000)
    --json                 Output structured JSON instead of formatted text digest
    -h, --help             Show this help message
"""
import sys
import os
import re
import json
import argparse
from typing import Any

def sift_and_cluster_logs(logs: list[dict] | list[str] | str, max_output_chars: int = 4000) -> dict[str, Any]:
    """Cluster raw log entries and isolate root cause candidates.

    Returns:
        dict containing:
          - 'summary': High-level text summary of the incident
          - 'root_cause_candidates': List of top log messages likely indicating the initial trigger
          - 'clusters': List of dicts with cluster signatures, counts, and sample lines
          - 'stats': Metrics on raw count, clusters count, and reduction ratio
    """
    import json
    import re
    from typing import Any

    def extract_timestamp(msg: str) -> str:
        # Match ISO/RFC3339 formats
        iso_match = re.search(r"\b\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:?\d{2})?\b", msg)
        if iso_match:
            return iso_match.group(0)
        # Match other standard date formats
        std_match = re.search(r"\b\d{4}/\d{2}/\d{2} \d{2}:\d{2}:\d{2}\b", msg)
        if std_match:
            return std_match.group(0)
        # Match syslog style: Oct 24 12:34:56
        syslog_match = re.search(r"\b(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)\s+\d{1,2}\s+\d{2}:\d{2}:\d{2}\b", msg, re.I)
        if syslog_match:
            return syslog_match.group(0)
        return ""

    def to_normalized_ts(ts_str: str) -> str:
        if not ts_str:
            return ""
        ts_str = ts_str.replace(",", ".")
        months = {"jan": "01", "feb": "02", "mar": "03", "apr": "04", "may": "05", "jun": "06", 
                  "jul": "07", "aug": "08", "sep": "09", "oct": "10", "nov": "11", "dec": "12"}
        m = re.search(r"(\d{4})[-/](\d{2})[-/](\d{2})[T ](\d{2}):(\d{2}):(\d{2})(?:\.(\d+))?", ts_str)
        if m:
            year, month, day, hour, minute, second, fraction = m.groups()
            fraction = (fraction or "")[:6].ljust(6, "0")
            return f"{year}-{month}-{day}T{hour}:{minute}:{second}.{fraction}"
        m = re.search(r"\b(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)\s+(\d{1,2})\s+(\d{2}):(\d{2}):(\d{2})", ts_str, re.I)
        if m:
            mon_str, day_str, hour, minute, second = m.groups()
            month = months.get(mon_str.lower(), "01")
            day = day_str.zfill(2)
            return f"2024-{month}-{day}T{hour}:{minute}:{second}.000000"
        return ts_str

    def extract_sig_base(msg: str) -> str:
        lines = [line.strip() for line in msg.splitlines() if line.strip()]
        if not lines:
            return ""
        for line in reversed(lines):
            if (line.startswith("at ") or line.startswith("File ") or 
                "stack traceback" in line or line.startswith("from ") or
                line.startswith("...") or "frames omitted" in line or 
                "common frames" in line or line == "..." or
                (line.startswith("[") and line.endswith("]"))):
                continue
            l_lower = line.lower()
            if any(k in l_lower for k in ["error", "exception", "panic", "fatal", "failed", "crash", "denied", "invalid", "cause"]):
                return line
        if lines:
            for line in lines:
                if not (line.startswith("Traceback") or line.startswith("at ") or line.startswith("File ") or 
                        "stack traceback" in line or line.startswith("...") or "frames omitted" in line):
                    return line
            return lines[0]
        return ""

    def clean_signature(text: str) -> str:
        # Remove various timestamp formats
        text = re.sub(r"\b\d{4}[-/]\d{2}[-/]\d{2}[T \-]?\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:?\d{2})?\b", "", text)
        text = re.sub(r"\b\d{2}:\d{2}:\d{2}(?:\.\d+)?\b", "", text)
        # Remove dates like Oct 24, 2023
        text = re.sub(r"\b(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)\s+\d{1,2}\b", "", text, flags=re.I)
        # Clean leading non-alphanumeric chars (leftovers from stripping timestamps/brackets)
        text = text.strip()
        # Remove standard log level prefixes at the beginning
        text = re.sub(r"^[^a-zA-Z0-9]*(?:INFO|WARN|WARNING|ERROR|ERR|DEBUG|FATAL|CRITICAL|CRIT|SYSTEM|SYS)\b[^a-zA-Z0-9]*", "", text, flags=re.I)
        # Remove absolute and relative paths
        text = re.sub(r"\b(?:/[a-zA-Z0-9_\.\-]+)+", "<PATH>", text)
        text = re.sub(r"\b[a-zA-Z]:\\(?:[a-zA-Z0-9_\.\-]+\\)*[a-zA-Z0-9_\.\-]+", "<PATH>", text)
        # Clean line numbers and function names in stack traces
        text = re.sub(r"\bline \d+\b", "line <N>", text, flags=re.I)
        text = re.sub(r":\d+\b", ":<N>", text)
        # Remove k8s pod/deployment suffixes: e.g., -7c6f49f49f-z7x9v
        text = re.sub(r"-[a-f0-9]{8,10}-[a-z0-9]{5}\b", "-<POD-HASH>", text)
        # Remove general random hashes: must contain both letters and digits, length 5-12
        text = re.sub(r"\b(?=[a-zA-Z]*\d)(?=\d*[a-zA-Z])[a-zA-Z0-9]{5,12}\b", "<HASH>", text)
        # Remove UUIDs
        text = re.sub(r"\b[0-9a-fA-F]{8,16}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12,}\b", "<ID>", text)
        # Remove Hex tokens / IDs
        text = re.sub(r"\b0x[0-9a-fA-F]+\b", "<HEX>", text)
        text = re.sub(r"\b[0-9a-fA-F]{8,}\b", "<ID>", text)
        # Remove IP addresses
        text = re.sub(r"\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b", "<IP>", text)
        # Remove email addresses and URLs
        text = re.sub(r"\bhttps?://\S+\b", "<URL>", text)
        text = re.sub(r"\b[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}\b", "<EMAIL>", text)
        # Protect HTTP status codes
        text = re.sub(r"\b(100|101|200|201|202|204|206|301|302|304|400|401|403|404|405|409|415|422|429|500|501|502|503|504)\b", r"HTTPSTATUS\1", text)
        # Remove Numbers (including floats)
        text = re.sub(r"\b\d+(?:\.\d+)+\b", "<N>", text)
        text = re.sub(r"\b\d+\b", "<N>", text)
        # Restore HTTP status codes
        text = re.sub(r"HTTPSTATUS(\d+)", r"\1", text)
        # Remove request IDs or traces
        text = re.sub(r"\[req_id=[^\]]+\]", "", text)
        text = re.sub(r"\[trace_id=[^\]]+\]", "", text)
        text = re.sub(r"\b(?:req|request|tx|trace|span|session|user|job|task|op|operation)-[a-zA-Z0-9_-]+\b", "<ID>", text, flags=re.I)
        text = re.sub(r"req-\w+", "<REQ>", text)
        # Clean punctuation boundaries
        text = re.sub(r"^[^a-zA-Z0-9]+", "", text)
        text = re.sub(r"[^a-zA-Z0-9]+$", "", text)
        # Remove specific symbols and extra whitespace
        text = re.sub(r"\s+", " ", text).strip()
        return text

    raw_entries: list[dict] = []

    # Helper to retrieve message from standard structures
    def get_entry_message(e: dict) -> str:
        msg = e.get("textPayload") or ""
        if not msg and "jsonPayload" in e:
            try:
                jp = e["jsonPayload"]
                if isinstance(jp, dict):
                    msg = (jp.get("message") or jp.get("msg") or jp.get("log") or 
                           jp.get("error") or jp.get("err") or jp.get("exception") or 
                           jp.get("reason") or jp.get("text") or jp.get("detail") or 
                           jp.get("messageText") or json.dumps(jp))
                else:
                    msg = str(jp)
            except Exception:
                msg = str(e["jsonPayload"])
        if not msg and "message" in e:
            msg = str(e["message"])
        if not msg and "log" in e:
            msg = str(e["log"])
        return msg

    # 1. Parse and normalize inputs
    if isinstance(logs, str):
        try:
            parsed = json.loads(logs)
            if isinstance(parsed, list):
                raw_entries = [e if isinstance(e, dict) else {"textPayload": str(e)} for e in parsed]
            elif isinstance(parsed, dict):
                raw_entries = [parsed]
            else:
                raw_entries = [{"textPayload": line} for line in logs.splitlines() if line.strip()]
        except Exception:
            lines = [line for line in logs.splitlines() if line.strip()]
            grouped_lines = []
            for line in lines:
                if grouped_lines and (line.startswith(" ") or line.startswith("\t") or line.strip().startswith("at ") or line.strip().startswith("Caused by:") or line.strip().startswith("... ") or not re.search(r"^\d{4}|\b(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)\b|^\[(?:INFO|WARN|ERR|DEBUG|FATAL)\]", line)):
                    grouped_lines[-1] = grouped_lines[-1] + "\n" + line
                else:
                    grouped_lines.append(line)
            raw_entries = [{"textPayload": line} for line in grouped_lines]
    elif isinstance(logs, list):
        for item in logs:
            if isinstance(item, dict):
                raw_entries.append(dict(item))
            else:
                raw_entries.append({"textPayload": str(item)})

    # Pass to group consecutive multiline/traceback entries if they were split
    grouped_entries = []
    for entry in raw_entries:
        msg = get_entry_message(entry)
        if (grouped_entries and msg and 
            (msg.startswith(" ") or msg.startswith("\t") or msg.startswith("at ") or msg.startswith("Caused by:") or msg.startswith("... ") or
             not re.search(r"^\d{4}|\b(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)\b|^\[(?:INFO|WARN|ERR|DEBUG|FATAL)\]", msg))):
            prev = grouped_entries[-1]
            appended = False
            for k in ["textPayload", "message", "log"]:
                if k in prev and prev[k]:
                    prev[k] = str(prev[k]) + "\n" + msg
                    appended = True
                    break
            if not appended:
                if "jsonPayload" in prev and isinstance(prev["jsonPayload"], dict):
                    jp = prev["jsonPayload"]
                    for k in ["message", "msg", "log", "error", "err", "exception", "reason", "text", "detail", "messageText"]:
                        if k in jp:
                            jp[k] = str(jp[k]) + "\n" + msg
                            appended = True
                            break
                    if not appended:
                        jp["message"] = msg
                        appended = True
                else:
                    prev["textPayload"] = msg
        else:
            grouped_entries.append(dict(entry))
    raw_entries = grouped_entries

    if not raw_entries:
        return {
            "summary": "No log entries provided.",
            "root_cause_candidates": [],
            "clusters": [],
            "stats": {"raw_entries_count": 0, "clusters_count": 0, "compression_ratio": 0.0}
        }

    # 2. Extract message text, severity, and timestamp per entry
    processed = []
    for e in raw_entries:
        msg = get_entry_message(e)

        # Extract severity with multiple fallbacks
        sev = "INFO"
        for field in ["severity", "level", "log_level", "levelname"]:
            if field in e and e[field]:
                sev = str(e[field]).upper()
                break
        else:
            if "jsonPayload" in e and isinstance(e["jsonPayload"], dict):
                jp = e["jsonPayload"]
                for field in ["severity", "level", "log_level", "levelname"]:
                    if field in jp and jp[field]:
                        sev = str(jp[field]).upper()
                        break

        # Normalize severity
        sev = sev.strip().upper()
        if sev == "WARN":
            sev = "WARNING"
        elif sev == "ERR":
            sev = "ERROR"
        elif sev == "CRIT":
            sev = "CRITICAL"

        if sev == "INFO" and e.get("stream") == "stderr":
            sev = "ERROR"

        # Upgrade severity based on message content
        msg_lower = msg.lower()
        prefix = msg[:200].upper()
        if (sev != "CRITICAL" and 
            (re.search(r"\b(CRITICAL|FATAL|EMERGENCY|PANIC|CRIT)\b", prefix) or 
             "oomkilled" in msg_lower or "out of memory" in msg_lower or
             "exit code 137" in msg_lower or "exit status 137" in msg_lower)):
            sev = "CRITICAL"
        if sev in ["INFO", "WARNING", "DEBUG"]:
            if (re.search(r"\b(ERROR|ERR)\b", prefix) or 
                re.search(r"\b[\[\(](ERROR|ERR|CRIT)[\]\)]\b", prefix) or
                "exception" in msg_lower or "traceback" in msg_lower or 
                "nullpointer" in msg_lower or "\tat " in msg or
                "unauthorized" in msg_lower or "permission denied" in msg_lower):
                sev = "ERROR"
            elif (re.search(r"\b(WARNING|WARN)\b", prefix) or 
                  re.search(r"^[W]\d{4}\b", prefix) or 
                  re.search(r"\b[\[\(](WARNING|WARN)[\]\)]\b", prefix)):
                sev = "WARNING"

        # Parse timestamp
        ts = ""
        for k in ["timestamp", "time"]:
            if k in e and e[k]:
                ts = str(e[k])
                break
        if not ts and "metadata" in e and isinstance(e["metadata"], dict):
            m = e["metadata"]
            for k in ["timestamp", "time"]:
                if k in m and m[k]:
                    ts = str(m[k])
                    break
        if not ts:
            ts = extract_timestamp(msg)

        processed.append({"message": msg.strip(), "severity": sev, "timestamp": ts, "raw": e})

    # Sort chronological by normalizing and interpolating missing timestamps
    for i, item in enumerate(processed):
        item["norm_ts"] = to_normalized_ts(item["timestamp"])
        item["orig_idx"] = i

    has_ts_count = sum(1 for item in processed if item["norm_ts"])
    if has_ts_count > len(processed) * 0.3:
        current_ts = ""
        for item in processed:
            if item["norm_ts"]:
                current_ts = item["norm_ts"]
            else:
                item["norm_ts"] = current_ts
        current_ts = ""
        for item in reversed(processed):
            if item["norm_ts"]:
                current_ts = item["norm_ts"]
            else:
                if not item["norm_ts"]:
                    item["norm_ts"] = current_ts
        processed.sort(key=lambda x: (x["norm_ts"] or "9999-12-31T23:59:59", x["orig_idx"]))

    # 3. Cluster recurring entries to reduce noise first
    clusters_dict: dict[str, dict[str, Any]] = {}
    for item in processed:
        msg = item["message"]
        sig_base = extract_sig_base(msg)
        sig = clean_signature(sig_base)
        if not sig:
            sig = "empty message"

        item["signature"] = sig

        if sig not in clusters_dict:
            clusters_dict[sig] = {
                "signature": sig[:200] + "..." if len(sig) > 200 else sig,
                "count": 0,
                "severity": item["severity"],
                "first_seen": item["timestamp"],
                "last_seen": item["timestamp"],
                "sample": msg[:300],
                "first_seen_norm": "",
                "last_seen_norm": ""
            }
        cluster = clusters_dict[sig]
        cluster["count"] += 1
        
        # Max severity propagation
        sev_priority = {"EMERGENCY": 6, "CRITICAL": 5, "FATAL": 4, "ERROR": 3, "WARNING": 2, "INFO": 1, "DEBUG": 0}
        current_sev_prio = sev_priority.get(cluster["severity"], 0)
        item_sev_prio = sev_priority.get(item["severity"], 0)
        if item_sev_prio > current_sev_prio:
            cluster["severity"] = item["severity"]

        ts = item["timestamp"]
        norm_ts = item["norm_ts"]
        if ts and norm_ts:
            if not cluster["first_seen_norm"] or norm_ts < cluster["first_seen_norm"]:
                cluster["first_seen_norm"] = norm_ts
                cluster["first_seen"] = ts
            if not cluster["last_seen_norm"] or norm_ts > cluster["last_seen_norm"]:
                cluster["last_seen_norm"] = norm_ts
                cluster["last_seen"] = ts

    # Remove internal sorting fields
    for cluster in clusters_dict.values():
        cluster.pop("first_seen_norm", None)
        cluster.pop("last_seen_norm", None)

    clusters = list(clusters_dict.values())
    clusters.sort(key=lambda c: -c["count"])

    # 4. Identify and score Root Cause Candidates
    rc_by_sig = {}
    total_logs_count = len(processed)

    for idx, item in enumerate(processed):
        msg = item["message"]
        sev = item["severity"]
        sig = item["signature"]
        if not msg:
            continue

        score = 0
        
        # Temporal boost: earlier logs are more likely to be the primary trigger
        if total_logs_count > 1:
            temporal_boost = 10.0 * (1.0 - (idx / (total_logs_count - 1)))
            score += temporal_boost

        # Severity score contribution
        sev_scores = {"EMERGENCY": 20, "CRITICAL": 20, "FATAL": 20, "ERROR": 12, "WARNING": 5}
        score += sev_scores.get(sev, 0)
        
        # High-signal patterns indicating primary root causes
        patterns_to_check = [
            (r"(?:OOMKilled|Memory limit exceeded|Memory limit reached|exit\s+(?:code|status)\s+137|exited\s+with\s+code\s+137|cgroup memory|OutOfMemoryError|java\.lang\.OutOfMemoryError|oom-killer|oom\s+killer|invoked\s+oom-killer|kernel:\s+out\s+of\s+memory|heap\s+space|GC\s+overhead\s+limit|heap\s+exhausted)", 35),
            (r"(?:Deadlock|deadlock\s+detected|pg_locks|connection\s+pool|db\s+connection\s+pool|too\s+many\s+connections|HikariPool|pool\s+exhausted|could\s+not\s+obtain\s+connection|connection\s+leak|LockWaitTimeoutException|lock\s+wait\s+timeout|Lock\s+wait\s+timeout\s+exceeded|transaction\s+timeout|TransactionTimeout|ConnectionPoolTimeoutException|ConnectionTimeoutException|Timeout waiting for connection|database connection threshold|database\s+is\s+locked|OperationalError)", 30),
            (r"(?:PermissionDenied|403\s+Permission|403\s+Forbidden|Forbidden|Unauthorized|AccessDenied|401\s+Unauthorized|credentials\s+not\s+found|Access\s+Denied|failed\s+to\s+authenticate|signature\s+verification\s+failed|token\s+expired|expired\s+token|authentication\s+failed|missing\s+credentials|IAM\s+permission|not\s+authorized|invalid_grant|invalid_client|service\s+account\s+not\s+found|storage\.objects\..*\baccess\b|NoSuchBucket|NoSuchKey|BucketNotFoundException|EntityNotFoundException|ResourceNotFoundException|SecretManager|Secret\s+not\s+found|unauthorized_client|unauthenticated|not\s+authenticated|credentials\s+expired)", 32),
            (r"(?:SSLError|certificate\s+expired|failed\s+to\s+fetch\s+jwks|expired\s+certificate|cert\s+expired|handshake\s+failed|SSL\s+validation\s+failed|x509:\s+certificate|invalid\s+certificate|PKIX\s+path\s+building|unable\s+to\s+get\s+local\s+issuer\s+certificate|certificate\s+verify\s+failed|SSLHandshakeException|CERT_HAS_EXPIRED)", 32),
            (r"(?:No\s+space\s+left\s+on\s+device|ENOSPC|Errno\s+28|disk\s+full|storage\s+full|Read-only\s+file\s+system|OutOfDisk|low\s+disk\s+space)", 30),
            (r"(?:gaierror|name\s+resolution|getaddrinfo\s+ENOTFOUND|dial\s+tcp\s+.*connection\s+refused|connection\s+refused|connection\s+timed\s+out|network\s+unreachable|socket\s+timeout|ConnectionError|Connection\s+failed|failed\s+to\s+connect|failed\s+to\s+resolve|no\s+such\s+host|lookup\s+failed|i/o\s+timeout|ETIMEDOUT|UnknownHostException|ConnectException|DNS\s+resolution\s+failed|temporary\s+failure\s+in\s+name\s+resolution|could\s+not\s+connect\s+to\s+server|is\s+not\s+running)", 26),
            (r"(?:UndefinedColumn|column\s+.*does\s+not\s+exist|Table\s+.*doesn't\s+exist|relation\s+.*does\s+not\s+exist|migration\s+failed|sql\s+syntax\s+error|unique\s+constraint|foreign\s+key|cannot\s+insert\s+NULL|schema\s+validation|Duplicate\s+entry|integrity\s+constraint\s+violation|ConstraintViolationException|syntax\s+error\s+or\s+access\s+violation|missing\s+column|Unknown\s+column|migration\s+error|migrations\s+pending|pending\s+migration)", 30),
            (r"(?:panic:|CrashLoopBackOff|unhandled\s+exception|NullPointerException|Segmentation\s+fault|segfault|core\s+dumped|SIGSEGV|SIGBUS|ZeroDivisionError|AttributeError|TypeError|RuntimeError|ValueError|KeyError|uncaught\s+exception|unhandled\s+rejection|fatal\s+error|IndexOutOfBoundsException|IllegalArgumentException|IllegalStateException|ArithmeticException|StackOverflowError|ClassCastException|AssertionError|NameError|OverflowError|LookupError|IndexError|ReferenceError|RangeError)", 28),
            (r"(?:Key\s+is\s+disabled|FailedPrecondition|KMS\s+error|decryption\s+failed|failed\s+to\s+decrypt|invalid\s+key|key\s+not\s+found)", 30),
            (r"(?:JSONDecodeError|invalid\s+configuration|configuration\s+error|failed\s+to\s+parse|yaml\s+parsing|unexpected\s+token|config\s+file\s+not\s+found|could\s+not\s+load\s+config|missing\s+configuration|environment\s+variable|settings\s+error|parsing\s+error|malformed\s+json|invalid\s+json|ConfigError|parse\s+error|invalid\s+yaml|TomlDecodeError)", 25),
            (r"(?:Too\s+Many\s+Requests|429\s+Too|quota\s+exceeded|rate\s+limit|API rate limit exceeded)", 25),
            (r"(?:EADDRINUSE|address\s+already\s+in\s+use|port\s+already\s+in\s+use|cannot\s+bind\s+to\s+port|failed\s+to\s+bind|listen\s+tcp)", 30),
            (r"(?:ModuleNotFoundError|ImportError|Cannot\s+find\s+module|class\s+not\s+found|no\s+module\s+named|failed\s+to\s+import|npm\s+ERR!|pip\s+install\s+failed|yarn\s+error)", 30),
            (r"(?:AssertionError|Assert\s+failed)", 25),
            (r"(?:CreateContainerConfigError|CreateContainerError|ImagePullBackOff|ErrImagePull|InvalidImageName|failed\s+to\s+pull\s+image|pull\s+access\s+denied|Evicted|eviction|MemoryPressure|DiskPressure|FailedCreatePodSandBox|FailedScheduling|FailedMount|NodeHasDiskPressure|NodeHasPIDPressure|NodeHasMemoryPressure|SandboxChanged|PodSandbox|back-off\s+pulling\s+image|rpc\s+error:\s+code\s+=\s+Unknown\s+desc\s+=\s+Error\s+response\s+from\s+daemon)", 35),
            (r"(?:TimeoutError|ReadTimeout|ConnectTimeout|ConnectionTimeout|RequestTimeout|gateway\s+timeout|read\s+timeout|timeout\s+waiting\s+for|timed\s+out\s+after|deadline\s+exceeded|context\s+deadline\s+exceeded|Gateway\s+Timeout|504\s+Gateway\s+Timeout|timeout\s+of\s+.*exceeded|RequestTimeoutException)", 28),
            (r"(?:FileNotFoundError|NoSuchFileException|no\s+such\s+file\s+or\s+directory|cannot\s+find\s+file|missing\s+file|file\s+not\s+found|directory\s+not\s+found|ENOENT|is\s+a\s+directory|PermissionError)", 30),
            (r"(?:CPU\s+limit|throttled|throttling|slow\s+query|high\s+cpu|cpu\s+usage|load\s+average|thread\s+starvation)", 25),
            (r"(?:Too\s+many\s+open\s+files|EMFILE|ENFILE|out\s+of\s+file\s+descriptors|thread\s+pool\s+exhausted|worker\s+pool\s+exhausted|socket\s+leak|file\s+descriptor\s+leak)", 30),
            (r"(?:ProtocolError|version\s+mismatch|incompatible\s+version|unsupported\s+version|API\s+version)", 25),
            (r"(?:ServiceUnavailable|Backing-off\s+restarting\s+failed\s+container|Error\s+syncing\s+pod)", 30),
            (r"(?:failed\s+to\s+start|failed\s+to\s+initialize|initialization\s+failed|could\s+not\s+start|startup\s+failed)", 28),
            (r"(?:corrupt|corrupted|malformed|bad\s+checksum|checksum\s+mismatch|invalid\s+checksum|integrity\s+check\s+failed)", 30),
            (r"(?:exit\s+(?:code|status)\s+(?!0\b)\d+|exited\s+with\s+code\s+(?!0\b)\d+)", 15)
        ]
        
        for pat, pts in patterns_to_check:
            if re.search(pat, msg, re.I):
                score += pts
                
        # Boost for tracebacks
        if "traceback" in msg.lower() or "stack traceback" in msg.lower() or "\tat " in msg or re.search(r"^\s+File\s+\".*\",\s+line\s+\d+", msg, re.M):
            score += 15
            
        # Downstream cascading penalties (symptoms, not root causes)
        penalties_to_check = [
            (r"(?:Health\s+check\s+failed|Liveness\s+probe|Readiness\s+probe|kube-probe|healthz|ELB-HealthChecker|Consul\s+Health\s+Check|AmazonRoute53|GoogleHC)", 20),
            (r"(?:500\s+Internal|503\s+Service\s+Unavailable|502\s+Bad\s+Gateway|504\s+Gateway\s+Timeout|upstream\s+connect\s+error|failed\s+to\s+forward\s+request)", 15),
            (r"(?:heartbeat|shutting\s+down|graceful\s+shutdown|cron\s+job|log\s+rotated|starting\s+worker|worker\s+process\s+.*exited|stopping\s+worker|received\s+signal\s+15|SIGTERM)", 15),
            (r"(?:retrying|retry\s+#?\d+|backoff)", 10),
            (r"(?:socket\s+hang\s+up|ECONNRESET|connection\s+reset\s+by\s+peer)", 8),
            (r"(?:GET|POST|PUT|DELETE|PATCH)\s+\S+\s+(?:500|502|503|504)", 20),
            (r"(?:request\s+failed|handler\s+failed|operation\s+failed|failed\s+request)", 10)
        ]
        for pat, pts in penalties_to_check:
            if re.search(pat, msg, re.I):
                score -= pts

        # Clean/Success/Benign log check for INFO/DEBUG logs
        if sev in ["INFO", "DEBUG"]:
            if not ("traceback" in msg.lower() or "\tat " in msg):
                success_keywords = r"\b(success|successfully|completed|active|ready|healthy|started|finished|resolved|loaded|updating|updated|monitoring|normal|ok)\b"
                if re.search(success_keywords, msg, re.I):
                    score -= 25

        # Incorporate cluster frequency into the score
        sig_count = clusters_dict.get(sig, {}).get("count", 1)
        if sig_count == 1:
            score += 5
        elif sig_count > 50 or (total_logs_count > 10 and sig_count > total_logs_count * 0.15):
            score -= 10

        if score >= 15:
            existing = rc_by_sig.get(sig)
            if existing is None or score > existing["score"]:
                rc_by_sig[sig] = {
                    "score": score,
                    "timestamp": item["timestamp"],
                    "norm_ts": item["norm_ts"],
                    "severity": sev,
                    "message": msg
                }

    root_causes = list(rc_by_sig.values())

    # Sort root causes by score descending, then normalized timestamp ascending (first seen trigger)
    root_causes.sort(key=lambda x: (-x["score"], x["norm_ts"] or "9999-12-31T23:59:59"))
    
    # Apply dynamic confidence filter: keep high-confidence candidates, always keep top 1
    if root_causes:
        max_score = root_causes[0]["score"]
        filtered_rc = []
        for rc in root_causes:
            if rc["score"] >= 30 or rc["score"] >= max_score - 12 or rc["score"] == max_score:
                filtered_rc.append(rc)
        root_causes = filtered_rc

    top_root_causes = root_causes[:6]

    # 5. Format compact incident summary with high diagnostic fidelity
    summary_parts = []
    summary_parts.append(f"Incident Analysis: {len(raw_entries)} log entries clustered into {len(clusters)} distinct signatures.")
    
    def short_ts(ts_str: str) -> str:
        if not ts_str:
            return ""
        m = re.search(r"(\d{2}:\d{2}:\d{2})", ts_str)
        if m:
            return m.group(1)
        return ts_str[-8:] if len(ts_str) > 8 else ts_str

    if top_root_causes:
        summary_parts.append("\n[PRIMARY ROOT CAUSE CANDIDATES]")
        for rc in top_root_causes[:6]:
            sig_base = extract_sig_base(rc['message'])
            cleaned_msg = sig_base[:180]
            if len(rc['message'].splitlines()) > 1 and sig_base != rc['message'].splitlines()[0]:
                first_line = rc['message'].splitlines()[0][:60]
                cleaned_msg = f"{cleaned_msg} (Context: {first_line})"
            t = short_ts(rc['timestamp']) or "unknown time"
            line = f" - [{rc['severity']}] @ {t}: {cleaned_msg}"
            current_len = sum(len(p) + 1 for p in summary_parts) + len(line)
            if current_len < max_output_chars - 400:
                summary_parts.append(line)
            else:
                summary_parts.append(" - ... (more root causes omitted to save space)")
                break

    summary_parts.append("\n[RECURRING LOG CLUSTERS]")
    for cl in clusters[:20]:
        time_range = ""
        if cl['first_seen'] or cl['last_seen']:
            t1 = short_ts(cl['first_seen'])
            t2 = short_ts(cl['last_seen'])
            if t1 == t2:
                time_range = f" @ {t1}"
            else:
                time_range = f" [{t1} -> {t2}]"
        
        line = f" - ({cl['count']}x) [{cl['severity']}] {cl['signature'][:100]}{time_range}"
        current_len = sum(len(p) + 1 for p in summary_parts) + len(line)
        if current_len < max_output_chars - 100:
            summary_parts.append(line)
        else:
            summary_parts.append(" - ... (more clusters omitted to save space)")
            break

    summary_text = "\n".join(summary_parts)
    if len(summary_text) > max_output_chars:
        summary_text = summary_text[:max_output_chars - 4] + "..."

    raw_bytes = sum(len(e["message"]) for e in processed) or 1
    out_bytes = len(summary_text)
    comp_ratio = max(0.0, min(1.0, 1.0 - (out_bytes / raw_bytes)))

    return {
        "summary": summary_text,
        "root_cause_candidates": top_root_causes,
        "clusters": clusters,
        "stats": {
            "raw_entries_count": len(raw_entries),
            "clusters_count": len(clusters),
            "compression_ratio": round(comp_ratio, 4),
        }
    }

def main():
    parser = argparse.ArgumentParser(
        description="Cluster Cloud Run & K8s logs and extract root cause candidates."
    )
    parser.add_argument("file", nargs="?", default="-", help="Input file (default: stdin)")
    parser.add_argument("--max-chars", type=int, default=4000, help="Max character length of output digest")
    parser.add_argument("--json", action="store_true", help="Output JSON structure instead of text summary")

    args = parser.parse_args()

    if args.file == "-":
        content = sys.stdin.read()
    else:
        with open(args.file, "r", encoding="utf-8") as f:
            content = f.read()

    result = sift_and_cluster_logs(
        content,
        max_output_chars=args.max_chars,
    )

    if args.json:
        print(json.dumps(result, indent=2))
    else:
        print(result["summary"])


if __name__ == "__main__":
    main()
