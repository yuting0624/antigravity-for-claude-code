"""Judge parsing and analysis tests. Each docstring names the mutation it catches."""
import os
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "harness"))
import analyze  # noqa: E402
import judge  # noqa: E402
import schedule  # noqa: E402

GOOD = '{"scores":{"consistency":4,"edge_cases":3,"scope":5,"readability":4,"robustness":3,"maintainability":4},"rationale":{"consistency":"a","edge_cases":"b","scope":"c","readability":"d","robustness":"e","maintainability":"f"},"flags":[]}'


class JudgeParse(unittest.TestCase):
    def test_plain_and_fenced_and_trailing_prose(self):
        for text in (GOOD, "```json\n" + GOOD + "\n```", "Here is my review:\n" + GOOD + "\nDIGEST: done"):
            obj, why = judge.parse_scores(text)
            self.assertIsNotNone(obj, why)
            self.assertEqual(obj["scores"]["scope"], 5)

    def test_out_of_range_and_missing_axis_rejected(self):
        """Accepting a 6, a float, or a missing axis would silently distort means."""
        self.assertIsNone(judge.parse_scores(GOOD.replace('"scope":5', '"scope":6'))[0])
        self.assertIsNone(judge.parse_scores(GOOD.replace('"scope":5', '"scope":4.5'))[0])
        self.assertIsNone(judge.parse_scores(GOOD.replace('"scope":5,', ''))[0])
        self.assertIsNone(judge.parse_scores(GOOD.replace('"flags":[]', '"flags":["made_up"]'))[0])
        self.assertIsNone(judge.parse_scores("no json here")[0])

    def test_strip_tests_from_patch_drops_index_lines_and_test_hunks(self):
        patch = "diff --git a/x_test.go b/x_test.go\nindex 1..2 100644\n+t\ndiff --git a/x.go b/x.go\nindex 3..4 100644\n--- a/x.go\n+++ b/x.go\n+c\n"
        out = judge.strip_tests_from_patch(patch)
        self.assertNotIn("x_test.go", out); self.assertNotIn("index ", out); self.assertIn("+c", out)

    def test_touched_files_marks_new(self):
        patch = "diff --git a/a.go b/a.go\nnew file mode 100644\n+x\ndiff --git a/b.go b/b.go\n--- a/b.go\n+++ b/b.go\n+y\n"
        self.assertEqual(judge.touched_files(patch), [("a.go", True), ("b.go", False)])


def _run(task, arm, cost, passed, size="medium", **kw):
    r = {"run_key": "%s__%s__r1" % (task, arm), "task_id": task, "arm": arm, "size_class": size, "status": "ok", "violations": [],
         "cost": {"total_usd": cost, "claude_usd": cost, "gemini_usd": 0.0}, "outcome": {"pass": passed, "hidden_pass": passed},
         "claude": {"num_turns": 10, "permission_denials": 0, "warm_start": False, "subtype": "success", "usage_reconciles": True},
         "agy": {"delegations": 0}, "writes": {"agy": 0, "claude_bash": 0}, "agent_wall_s": 100}
    r.update(kw)
    return r


class Analysis(unittest.TestCase):
    def test_cost_of_pass_counts_failed_runs_in_the_numerator(self):
        """Cost per trial (or dropping failures) would flatter an arm that fails cheaply."""
        a = analyze.arm_summary([_run("t1", "x", 10.0, True), _run("t1", "x", 2.0, False)])
        self.assertEqual(a["cost_of_pass_usd"], 12.0)
        self.assertEqual(a["cost_pass_median"], 10.0)
        self.assertEqual(a["pass_rate"], 0.5)

    def test_violations_are_excluded_from_the_arm_numbers_but_counted(self):
        a = analyze.arm_summary([_run("t1", "x", 10.0, True), _run("t1", "x", 1.0, True, violations=["executor_web_access"])])
        self.assertEqual(a["runs_ok"], 1); self.assertEqual(a["excluded"], 1)
        self.assertEqual(a["violations"], {"executor_web_access": 1})

    def test_bootstrap_is_seeded_and_bounded(self):
        """An unseeded RNG makes the CI irreproducible; a percentile off-by-one leaves the CI."""
        runs = []
        for i, t in enumerate(("t1", "t2", "t3", "t4")):
            runs += [_run(t, "solo", 10.0 + i, True), _run(t, "hyb", 5.0 + i, True)]
        pt = analyze.per_task_cost_of_pass(runs)
        r1 = analyze.bootstrap_ratio(pt, "hyb", "solo", sorted(pt), 500, 7)
        r2 = analyze.bootstrap_ratio(pt, "hyb", "solo", sorted(pt), 500, 7)
        self.assertEqual(r1["ci95"], r2["ci95"])
        self.assertAlmostEqual(r1["point"], (5 + 6 + 7 + 8) / (10 + 11 + 12 + 13), places=4)
        self.assertLessEqual(r1["ci95"][0], r1["point"]); self.assertGreaterEqual(r1["ci95"][1], r1["point"])
        self.assertEqual(r1["n_tasks"], 4)

    def test_bootstrap_reports_undefined_when_an_arm_never_passes(self):
        runs = [_run("t1", "solo", 10.0, True), _run("t1", "hyb", 5.0, False)]
        pt = analyze.per_task_cost_of_pass(runs)
        r = analyze.bootstrap_ratio(pt, "hyb", "solo", ["t1"], 50, 1)
        self.assertIsNone(r["point"]); self.assertEqual(r["undefined_draws"], 50)

    def test_spearman_and_pearson(self):
        self.assertEqual(analyze.spearman([1, 2, 3, 4], [10, 20, 30, 40]), 1.0)
        self.assertEqual(analyze.spearman([1, 2, 3, 4], [40, 30, 20, 10]), -1.0)
        self.assertIsNone(analyze.spearman([1, 2], [1, 2]))
        self.assertIsNone(analyze.pearson([1, 1, 1], [1, 2, 3]))


if __name__ == "__main__":
    unittest.main()


class Scheduler(unittest.TestCase):
    def _items(self):
        return [
            {"task_id": "t1", "arm": "solo", "rep": 1, "status": "done", "history": [{"ended_ts": 1000.0}]},
            {"task_id": "t2", "arm": "solo", "rep": 1, "status": "pending", "history": []},
            {"task_id": "t1", "arm": "hyb", "rep": 1, "status": "pending", "history": []},
            {"task_id": "t3", "arm": "hyb", "rep": 1, "status": "pending", "history": []},
        ]

    def test_same_arm_and_same_task_gaps(self):
        """Dropping the arm rule lets item 1 start at t=1100; dropping the task rule lets item 2."""
        items = self._items()
        self.assertEqual(schedule.eligible(items, 1100.0, 300), 3)   # t3/hyb: neither arm nor task ran recently
        self.assertEqual(schedule.eligible(items, 1400.0, 300), 1)   # after the gap the earlier item is taken first

    def test_running_arm_or_task_blocks(self):
        items = self._items(); items[3]["status"] = "running"
        self.assertIsNone(schedule.eligible(items, 1100.0, 300))    # hyb running, solo too recent, t1 too recent

    def test_classify_infra_vs_final(self):
        infra = {"claude": {"subtype": "error_during_execution", "errors": ["529 overloaded"], "transcript": {"present": True, "tool_calls": {}}}, "agy": {}}
        final = {"claude": {"subtype": "success", "errors": [], "transcript": {"present": True, "tool_calls": {"Bash": 3}}, "total_cost_usd": 1.0}, "agy": {}}
        quota = {"claude": {"subtype": "success", "errors": [], "transcript": {"present": True, "tool_calls": {"Bash": 3}}, "total_cost_usd": 1.0},
                 "agy": {"delegations": 2, "usage_lines": 0, "signals": {"QUOTA_EXHAUSTED": 2}}}
        self.assertEqual(schedule.classify(infra, None), "infra")
        self.assertEqual(schedule.classify(final, None), "final")
        self.assertEqual(schedule.classify(quota, None), "infra")
        self.assertEqual(schedule.classify(None, "Traceback"), "infra")
        self.assertEqual(schedule.classify({"env_failure": "plugin_bin_missing", "claude": {"subtype": "success", "errors": [], "transcript": {"present": True, "tool_calls": {"Bash": 5}}, "total_cost_usd": 1.9}, "agy": {}}, None), "infra")
        slept_ok = {"suspended_s": 1164.6, "claude": {"subtype": "success", "errors": [], "transcript": {"present": True, "tool_calls": {"Bash": 3}}, "total_cost_usd": 2.2}, "agy": {}}
        slept_dead = {"suspended_s": 1164.6, "claude": {"subtype": "error_during_execution", "errors": [], "transcript": {"present": True, "tool_calls": {"Bash": 3}}, "total_cost_usd": 2.2}, "agy": {}}
        self.assertEqual(schedule.classify(slept_ok, None), "final")      # completed after the wake: kept, flagged
        self.assertEqual(schedule.classify(slept_dead, None), "suspended")  # died of the sleep: rerun

    def test_queue_order_alternates(self):
        """Consecutive items must differ in arm (rotation) so two lanes rarely wait on the arm gap."""
        import tempfile, os
        os.environ["AGY_BENCH_RESULTS_DIR"] = tempfile.mkdtemp()
        import importlib, common
        importlib.reload(common); importlib.reload(schedule)
        q = schedule.build_queue("qtest", ["a", "b", "c"], 2, 1, None)
        items = q["items"]
        if items:
            self.assertTrue(all(items[i]["arm"] != items[i + 1]["arm"] for i in range(len(items) - 1)))
            self.assertEqual(len(items), len(q["tasks"]) * 3 * 2)
