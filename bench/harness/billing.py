"""Reconcile computed costs against the GCP billing export for a time window.

    bench.py billing --run-id pilot [--table <project.dataset.table>] [--slack-h 3]

For every run in the run id, the window is [min started_at, max ended_at] widened by
`--slack-h` hours (the export is delayed and bucketed by usage_start_time). It sums the
export's `cost` by model family for SKUs that name Claude Opus 5 / Sonnet 5 and Gemini
3.8 Flash / 3.1 Pro, and prints them next to the harness totals. Other activity on the
project inside the window (other sessions, other agents) lands in the same SKUs, so the
gap is reported per family and never "corrected": a quiet window is the operator's job.

Requires the `bq` CLI and read access to the export; results are written to
results/<run-id>/billing.json for the write-up.
"""
from __future__ import annotations

import datetime as dt
import json
import os
from typing import Dict, List

from common import RESULTS_DIR, read_json, run, write_json

DEFAULT_TABLE = "data-agent-bq.billing_export.gcp_billing_export_v1_01F395_17E646_FF0C82"
FAMILIES = {
    "claude_opus": "LOWER(sku.description) LIKE '%claude opus 5%'",
    "claude_sonnet": "LOWER(sku.description) LIKE '%claude sonnet 5%'",
    "claude_fable": "LOWER(sku.description) LIKE '%claude fable 5%'",
    "gemini_flash_38": "LOWER(sku.description) LIKE '%gemini 3.8 flash%'",
    "gemini_pro_31": "LOWER(sku.description) LIKE '%gemini 3.1 pro%'",
}


def window(run_id: str, slack_h: float) -> (str, str, List[dict]):
    import glob
    recs = [read_json(p) for p in glob.glob(os.path.join(RESULTS_DIR, run_id, "runs", "*", "run.json"))]
    starts = [r["started_at"] for r in recs if r.get("started_at")]
    ends = [r["ended_at"] for r in recs if r.get("ended_at")]
    if not starts:
        raise SystemExit("no runs with timestamps under %s" % run_id)
    s = dt.datetime.fromisoformat(min(starts).replace("Z", "+00:00")) - dt.timedelta(hours=slack_h)
    e = dt.datetime.fromisoformat(max(ends).replace("Z", "+00:00")) + dt.timedelta(hours=slack_h)
    return s.strftime("%Y-%m-%d %H:%M:%S"), e.strftime("%Y-%m-%d %H:%M:%S"), recs


def query(table: str, start: str, end: str) -> Dict[str, dict]:
    cases = " ".join("WHEN %s THEN '%s'" % (cond, fam) for fam, cond in FAMILIES.items())
    sql = """
SELECT CASE %s ELSE 'other' END AS family, sku.description AS sku, ROUND(SUM(cost), 4) AS cost_usd,
       SUM(usage.amount) AS usage_amount
FROM `%s`
WHERE usage_start_time >= TIMESTAMP('%s') AND usage_start_time < TIMESTAMP('%s')
  AND (LOWER(sku.description) LIKE '%%claude%%' OR LOWER(sku.description) LIKE '%%gemini%%')
GROUP BY 1, 2 ORDER BY 1, 3 DESC""" % (cases, table, start, end)
    r = run(["bq", "query", "--use_legacy_sql=false", "--format=json", "--max_rows=500", sql], timeout=300)
    if not r.ok:
        raise SystemExit("bq failed: %s" % r.err[-800:])
    rows = json.loads(r.out or "[]")
    fams: Dict[str, dict] = {}
    for row in rows:
        f = fams.setdefault(row["family"], {"cost_usd": 0.0, "skus": []})
        f["cost_usd"] += float(row["cost_usd"] or 0)
        f["skus"].append({"sku": row["sku"], "cost_usd": float(row["cost_usd"] or 0), "usage_amount": float(row["usage_amount"] or 0)})
    for f in fams.values():
        f["cost_usd"] = round(f["cost_usd"], 4)
    return fams


def reconcile(run_id: str, table: str = DEFAULT_TABLE, slack_h: float = 3.0) -> dict:
    start, end, recs = window(run_id, slack_h)
    bill = query(table, start, end)
    computed = {"claude_opus": 0.0, "claude_sonnet": 0.0, "gemini_flash_38": 0.0, "gemini_pro_31": 0.0}
    for r in recs:
        for model, mu in (r.get("claude", {}).get("model_usage") or {}).items():
            key = "claude_opus" if "opus" in model else ("claude_sonnet" if "sonnet" in model else None)
            if key:
                computed[key] += float(mu.get("costUSD") or 0)
        for tier, bt in (r.get("agy", {}).get("by_tier") or {}).items():
            key = "gemini_pro_31" if tier == "pro" else "gemini_flash_38"
            computed[key] += float(bt.get("usd") or 0)
    out = {"run_id": run_id, "table": table, "window_utc": [start, end], "slack_h": slack_h, "runs": len(recs),
           "families": {}}
    for fam in sorted(set(computed) | set(bill)):
        c = round(computed.get(fam, 0.0), 4)
        b = bill.get(fam, {}).get("cost_usd")
        out["families"][fam] = {"computed_usd": c, "billed_usd": b,
                                "gap_pct": (round((b - c) / c * 100, 1) if (b is not None and c > 0) else None),
                                "skus": bill.get(fam, {}).get("skus", [])}
    out["note"] = ("billed includes every use of these SKUs on the project inside the window, not only the "
                   "benchmark; a positive gap is other activity or export bucketing, a negative gap means the "
                   "harness over-counted and must be investigated.")
    write_json(os.path.join(RESULTS_DIR, run_id, "billing.json"), out)
    return out
