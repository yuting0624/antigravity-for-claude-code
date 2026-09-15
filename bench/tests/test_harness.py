"""Harness self-tests. Each test's docstring names the mutation it catches."""
import json
import os
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "harness"))
import agy_usage  # noqa: E402
import claude_usage  # noqa: E402
import common  # noqa: E402
import score  # noqa: E402

FIX = os.path.join(HERE, "fixtures")


def _write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(text)
    return path


class Pricing(unittest.TestCase):
    def setUp(self):
        self.p = common.Prices()

    def test_claude_list_price_uses_all_four_terms(self):
        """Dropping the cache multipliers, or pricing cache_read at the input rate, changes this."""
        usd, flags = self.p.price_claude("claude-opus-5[1m]", 1_000_000, 100_000, 200_000, 3_000_000)
        # 5 + 2.5 + 0.2*5*1.25 + 3*5*0.1 = 5 + 2.5 + 1.25 + 1.5
        self.assertAlmostEqual(usd, 10.25, places=6)
        self.assertEqual(flags, [])

    def test_claude_unknown_model_is_flagged_not_zero(self):
        usd, flags = self.p.price_claude("claude-haiku-4-5", 10, 10, 0, 0)
        self.assertIsNone(usd)
        self.assertTrue(flags and flags[0].startswith("no_claude_rate_for"))

    def test_gemini_three_terms_no_subtraction(self):
        """Subtracting cache_read from input (the Claude convention) would give 0.75*0 here."""
        usd, flags = self.p.price_gemini({"input": 1_000_000, "output": 100_000, "cache_read": 1_000_000}, "gemini_flash_38")
        self.assertAlmostEqual(usd, 0.75 + 0.375 + 0.075, places=6)
        self.assertEqual(flags, [])

    def test_gemini_pro_has_no_cached_rate_and_says_so(self):
        usd, flags = self.p.price_gemini({"input": 0, "output": 0, "cache_read": 1_000_000}, "gemini_pro")
        self.assertAlmostEqual(usd, 2.0, places=6)
        self.assertIn("no_cached_rate_for:gemini_pro", flags)

    def test_unknown_tier_priced_as_pro_and_flagged(self):
        """Pricing an unresolved line at flash would flatter the hybrid arm."""
        usd, flags = self.p.price_gemini({"input": 1_000_000, "output": 0, "cache_read": 0}, None)
        self.assertAlmostEqual(usd, 2.0, places=6)
        self.assertIn("unknown_tier_priced_as_pro", flags)

    def test_gemini_key_from_model_name_beats_tier(self):
        self.assertEqual(self.p.gemini_key("Gemini 3.1 Pro (High)", "flash")[0], "gemini_pro")
        self.assertEqual(self.p.gemini_key("Gemini 3.8 Flash (Low)", "")[0], "gemini_flash_38")
        self.assertEqual(self.p.gemini_key("", "flash-lo")[0], "gemini_flash")
        self.assertEqual(self.p.gemini_key("", "")[0], None)


class AgyUsage(unittest.TestCase):
    def setUp(self):
        self.p = common.Prices()
        self.tmp = tempfile.mkdtemp()

    def _log(self, lines):
        return _write(os.path.join(self.tmp, "agy_usage.log"), "\n".join(lines) + "\n")

    def test_invariant_violation_stops_scoring(self):
        """Removing check_invariant would silently price a mis-shaped line."""
        recs = agy_usage.parse_log(self._log([
            'AGY_USAGE {"status": "SUCCESS", "error": "", "usage": {"input": 10, "output": 5, "thinking": 0, "cache_read": 0, "total": 99}, "conversation_id": "c1"}']))
        with self.assertRaises(agy_usage.InvariantError):
            agy_usage.summarize(recs, self.p)

    def test_tier_join_order_field_then_cid_then_order_then_unknown(self):
        """Each join stage has its own counter; disabling one moves lines down the ladder."""
        cid_a = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        cid_b = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
        cid_c = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
        recs = agy_usage.parse_log(self._log([
            'AGY_USAGE {"status": "SUCCESS", "error": "", "usage": {"input": 100, "output": 10, "thinking": 0, "cache_read": 0, "total": 110}, "conversation_id": "%s", "model": "Gemini 3.1 Pro (High)", "tier": "pro"}' % cid_a,
            'AGY_USAGE {"status": "SUCCESS", "error": "", "usage": {"input": 100, "output": 10, "thinking": 0, "cache_read": 0, "total": 110}, "conversation_id": "%s"}' % cid_b,
            'AGY_USAGE {"status": "SUCCESS", "error": "", "usage": {"input": 100, "output": 10, "thinking": 0, "cache_read": 0, "total": 110}, "conversation_id": "%s"}' % cid_c,
            'AGY_SIGNAL {"status":"TIMEOUT","reason":"x","model":"Gemini 3.8 Flash (High)","retry":""}',
        ]))
        calls = [
            {"order": 1, "head": "agy-delegate", "tier": "pro", "model": "", "conversation_ids": []},
            {"order": 2, "head": "agy-delegate", "tier": "flash-lo", "model": "", "conversation_ids": [cid_b]},
            {"order": 3, "head": "agy-delegate", "tier": "flash", "model": "", "conversation_ids": []},
        ]
        s = agy_usage.summarize(recs, self.p, calls)
        self.assertEqual(s["join"], {"by_model_field": 1, "by_conversation_id": 1, "by_order": 0, "unresolved": 1})
        self.assertEqual(s["delegations"], 3)
        self.assertEqual(s["signals"], {"TIMEOUT": 1})
        self.assertIn("pro", s["by_tier"]); self.assertIn("flash-lo", s["by_tier"]); self.assertIn("unknown", s["by_tier"])
        self.assertIn("unknown_tier_priced_as_pro", s["flags"])

    def test_by_order_only_when_counts_match(self):
        """Pairing unequal lists in order would assign tiers to the wrong lines."""
        recs = agy_usage.parse_log(self._log([
            'AGY_USAGE {"status": "SUCCESS", "error": "", "usage": {"input": 1, "output": 1, "thinking": 0, "cache_read": 0, "total": 2}, "conversation_id": "d1"}',
            'AGY_USAGE {"status": "SUCCESS", "error": "", "usage": {"input": 1, "output": 1, "thinking": 0, "cache_read": 0, "total": 2}, "conversation_id": "d2"}']))
        calls = [{"order": 1, "head": "agy-delegate", "tier": "pro", "model": "", "conversation_ids": []},
                 {"order": 2, "head": "agy-delegate", "tier": "flash", "model": "", "conversation_ids": []}]
        s = agy_usage.summarize(recs, self.p, calls)
        self.assertEqual(s["join"]["by_order"], 2)
        s2 = agy_usage.summarize(recs, self.p, calls[:1])
        self.assertEqual(s2["join"]["unresolved"], 2)

    def test_pre_envelope_signal_counts_as_a_delegation(self):
        recs = agy_usage.parse_log(self._log(['AGY_SIGNAL {"status":"QUOTA_EXHAUSTED","reason":"x","model":"m","retry":"--continue"}']))
        s = agy_usage.summarize(recs, self.p)
        self.assertEqual(s["delegations"], 1)
        self.assertEqual(s["usage_lines"], 0)


class ClaudeUsage(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.p = common.Prices()

    def test_result_fields_and_recomputed_price(self):
        """The recomputation must read modelUsage per model, not `usage` totals."""
        res = {"type": "result", "subtype": "success", "num_turns": 7, "duration_ms": 1000, "total_cost_usd": 1.23,
               "usage": {"input_tokens": 10, "output_tokens": 20, "cache_creation_input_tokens": 30, "cache_read_input_tokens": 40},
               "modelUsage": {"claude-opus-5[1m]": {"inputTokens": 1_000_000, "outputTokens": 0, "cacheReadInputTokens": 0, "cacheCreationInputTokens": 0, "costUSD": 5.0},
                              "claude-haiku-4-5": {"inputTokens": 5, "outputTokens": 5, "cacheReadInputTokens": 0, "cacheCreationInputTokens": 0, "costUSD": 0.0}},
               "permission_denials": [{"tool_name": "Bash", "tool_input": {"command": "tee x"}}], "session_id": "s"}
        path = _write(os.path.join(self.tmp, "result.json"), json.dumps(res))
        r = claude_usage.parse_result(path)
        self.assertTrue(r["present"]); self.assertEqual(r["num_turns"], 7); self.assertEqual(len(r["permission_denials"]), 1)
        usd, flags = claude_usage.recompute_list_price(r["model_usage"], self.p)
        self.assertAlmostEqual(usd, 5.0, places=6)
        self.assertTrue(any("haiku" in f for f in flags))

    def test_transcript_sums_first_turn_and_agy_join_from_stdout_and_stderr(self):
        """cid must be found in toolUseResult.stdout, .stderr and tool_result content alike."""
        cid1 = "11111111-1111-4111-8111-111111111111"
        cid2 = "22222222-2222-4222-8222-222222222222"
        lines = [
            {"type": "assistant", "message": {"role": "assistant", "model": "claude-opus-5", "usage": {"input_tokens": 5, "output_tokens": 7, "cache_creation_input_tokens": 100, "cache_read_input_tokens": 0},
                                              "content": [{"type": "tool_use", "id": "t1", "name": "Bash", "input": {"command": "agy-delegate --tier pro --yolo --dir . 'x' 2>&1 | tail -3"}}]}},
            {"type": "user", "message": {"role": "user", "content": [{"type": "tool_result", "tool_use_id": "t1", "content": "digest"}]},
             "toolUseResult": {"stdout": 'AGY_USAGE {"conversation_id": "%s"}' % cid1, "stderr": ""}},
            {"type": "assistant", "message": {"role": "assistant", "model": "claude-opus-5", "usage": {"input_tokens": 5, "output_tokens": 7, "cache_creation_input_tokens": 0, "cache_read_input_tokens": 900},
                                              "content": [{"type": "tool_use", "id": "t2", "name": "Bash", "input": {"command": "agy-delegate -t flash-lo 'y'"}},
                                                          {"type": "tool_use", "id": "t3", "name": "Edit", "input": {}},
                                                          {"type": "tool_use", "id": "t4", "name": "WebFetch", "input": {}}]}},
            {"type": "user", "message": {"role": "user", "content": [{"type": "tool_result", "tool_use_id": "t2", "content": [{"type": "text", "text": "ok"}]}]},
             "toolUseResult": {"stdout": "", "stderr": 'AGY_USAGE {"conversation_id": "%s"}' % cid2}},
            {"type": "assistant", "isSidechain": True, "message": {"role": "assistant", "model": "claude-opus-5", "usage": {"input_tokens": 1, "output_tokens": 1}, "content": []}},
        ]
        path = _write(os.path.join(self.tmp, "main.jsonl"), "\n".join(json.dumps(l) for l in lines) + "\n")
        s = claude_usage.summarize_transcript(path)
        self.assertEqual(s["turns"], 3); self.assertEqual(s["output"], 15); self.assertEqual(s["cache_read"], 900)
        self.assertEqual(s["first_turn_cache_read"], 0)
        self.assertEqual(s["tool_calls"], {"Bash": 2, "Edit": 1, "WebFetch": 1})
        self.assertEqual(s["web_tool_calls"], 1); self.assertEqual(s["write_tool_calls"], 1)
        self.assertEqual([c["tier"] for c in s["agy_calls"]], ["pro", "flash-lo"])
        self.assertEqual(s["agy_calls"][0]["conversation_ids"], [cid1])
        self.assertEqual(s["agy_calls"][1]["conversation_ids"], [cid2])
        self.assertEqual(s["sidechain_turns"], 1)

    def test_transcript_usage_deduped_by_request_id(self):
        """One API request is written as several JSONL lines (text, thinking, each tool_use) with identical usage; summing every line doubles the cost."""
        lines = [
            {"type": "assistant", "requestId": "req_1", "message": {"role": "assistant", "id": "msg_1", "model": "m", "usage": {"input_tokens": 3, "output_tokens": 254, "cache_creation_input_tokens": 10, "cache_read_input_tokens": 20}, "content": [{"type": "text", "text": "x"}]}},
            {"type": "assistant", "requestId": "req_1", "message": {"role": "assistant", "id": "msg_1", "model": "m", "usage": {"input_tokens": 3, "output_tokens": 254, "cache_creation_input_tokens": 10, "cache_read_input_tokens": 20}, "content": [{"type": "tool_use", "id": "t1", "name": "Read", "input": {}}]}},
            {"type": "assistant", "requestId": "req_1", "message": {"role": "assistant", "id": "msg_1", "model": "m", "usage": {"input_tokens": 3, "output_tokens": 254, "cache_creation_input_tokens": 10, "cache_read_input_tokens": 20}, "content": [{"type": "tool_use", "id": "t2", "name": "Read", "input": {}}]}},
            {"type": "assistant", "requestId": "req_2", "message": {"role": "assistant", "id": "msg_2", "model": "m", "usage": {"input_tokens": 3, "output_tokens": 146, "cache_creation_input_tokens": 0, "cache_read_input_tokens": 0}, "content": [{"type": "tool_use", "id": "t3", "name": "Bash", "input": {"command": "ls"}}]}},
        ]
        path = _write(os.path.join(self.tmp, "dup.jsonl"), "\n".join(json.dumps(l) for l in lines) + "\n")
        s = claude_usage.summarize_transcript(path)
        self.assertEqual(s["turns"], 2)
        self.assertEqual(s["output"], 400)
        self.assertEqual(s["cache_creation"], 10)
        self.assertEqual(s["tool_calls"], {"Read": 2, "Bash": 1})

    def test_wrapper_not_found_is_counted(self):
        """A hybrid run whose shell says agy-delegate is missing is an environment failure, not the arm's."""
        lines = [{"type": "user", "message": {"role": "user", "content": [{"type": "tool_result", "tool_use_id": "t1", "content": "x"}]},
                  "toolUseResult": {"stdout": "", "stderr": "zsh: command not found: agy-delegate"}},
                 {"type": "user", "message": {"role": "user", "content": [{"type": "tool_result", "tool_use_id": "t2", "content": "x"}]},
                  "toolUseResult": {"stdout": "agy-delegate not found in PATH", "stderr": ""}}]
        path = _write(os.path.join(self.tmp, "nf.jsonl"), "\n".join(json.dumps(l) for l in lines) + "\n")
        self.assertEqual(claude_usage.summarize_transcript(path)["wrapper_not_found"], 2)

    def test_reconcile_flags_a_real_mismatch_only(self):
        res = {"usage": {"input_tokens": 100000, "output_tokens": 1000, "cache_creation_input_tokens": 0, "cache_read_input_tokens": 0}}
        ok = claude_usage.reconcile(res, {"input": 100500, "output": 1000, "cache_creation": 0, "cache_read": 0})
        bad = claude_usage.reconcile(res, {"input": 150000, "output": 1000, "cache_creation": 0, "cache_read": 0})
        self.assertTrue(ok["ok"]); self.assertFalse(bad["ok"])


class Scoring(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()

    def test_diff_classification_and_outside_author_set(self):
        """testdata/ and acceptance/ are tests, go.sum is gomod, a binary is stray, new code files are 'outside'."""
        patch = "\n".join([
            "diff --git a/internal/x/y.go b/internal/x/y.go", "--- a/internal/x/y.go", "+++ b/internal/x/y.go", "+a", "+b", "-c",
            "diff --git a/internal/x/y_test.go b/internal/x/y_test.go", "--- a/x", "+++ b/x", "+t",
            "diff --git a/internal/x/testdata/f.txt b/internal/x/testdata/f.txt", "--- a/x", "+++ b/x", "+d",
            "diff --git a/acceptance/testdata/a.txtar b/acceptance/testdata/a.txtar", "--- a/x", "+++ b/x", "+e",
            "diff --git a/go.sum b/go.sum", "--- a/x", "+++ b/x", "+h",
            "diff --git a/internal/x/z.go b/internal/x/z.go", "--- a/x", "+++ b/x", "+n1", "+n2",
            "diff --git a/README.md b/README.md", "--- a/x", "+++ b/x", "+doc",
            "diff --git a/bin/blob b/bin/blob", "Binary files a/bin/blob and b/bin/blob differ", ""])
        d = score.diff_stats(patch, ["internal/x/y.go"])
        self.assertEqual(d["files_touched"], 8)
        self.assertEqual((d["code_added"], d["code_removed"]), (4, 1))
        self.assertEqual(d["test_added"], 3)
        self.assertTrue(d["gomod_changed"])
        self.assertEqual(d["files_outside_author_set"], ["internal/x/z.go"])
        self.assertEqual(d["stray_binaries"], ["bin/blob"])
        self.assertEqual(d["doc_added"], 1)

    def test_go_test_json_names_failures(self):
        out = "\n".join(json.dumps(e) for e in [
            {"Action": "run", "Package": "p", "Test": "TestA"}, {"Action": "pass", "Package": "p", "Test": "TestA"},
            {"Action": "fail", "Package": "p", "Test": "TestB"}, {"Action": "fail", "Package": "p"},
            {"Action": "output", "Package": "q", "Output": "FAIL\tq [build failed]\n"}, {"Action": "fail", "Package": "q"},
            {"Action": "pass", "Package": "r"}])
        r = score.parse_go_test_json(out)
        self.assertEqual(r["failed_tests"], ["p.TestB"]); self.assertEqual(r["passed_tests"], 1)
        self.assertEqual(r["failed_packages"], ["p", "q"]); self.assertEqual(r["build_failed_packages"], ["q"])

    def test_write_attribution_by_tool_use_id(self):
        """An agy-delegate change must land in `agy`, an Edit in `claude_tool`, a stray Bash write in `claude_bash`."""
        ev = [
            {"event": "gate", "decision": "allow", "heads": ["agy-delegate"], "tool_use_id": "a", "command": "agy-delegate --yolo 'x'"},
            {"event": "PreToolUse", "tool_name": "Bash", "tool_use_id": "a", "head": "agy-delegate", "fp": "f0"},
            {"event": "PostToolUse", "tool_name": "Bash", "tool_use_id": "a", "head": "agy-delegate", "fp": "f1"},
            {"event": "PreToolUse", "tool_name": "Edit", "tool_use_id": "b", "head": "", "fp": "f1"},
            {"event": "PostToolUse", "tool_name": "Edit", "tool_use_id": "b", "head": "", "fp": "f2"},
            {"event": "gate", "decision": "block", "heads": ["tee"], "tool_use_id": "c", "command": "tee x"},
            {"event": "PreToolUse", "tool_name": "Bash", "tool_use_id": "d", "head": "go", "fp": "f2"},
            {"event": "PostToolUse", "tool_name": "Bash", "tool_use_id": "d", "head": "go", "fp": "f2"},
            {"event": "gate", "decision": "allow", "heads": ["cat"], "tool_use_id": "e", "command": "cat x"},
            {"event": "PreToolUse", "tool_name": "Bash", "tool_use_id": "e", "head": "cat", "fp": "f2"},
            {"event": "PostToolUse", "tool_name": "Bash", "tool_use_id": "e", "head": "cat", "fp": "f3"},
            {"event": "PreToolUse", "tool_name": "Bash", "tool_use_id": "f", "head": "go", "fp": "f4"},
        ]
        path = _write(os.path.join(self.tmp, "tool_trace.jsonl"), "\n".join(json.dumps(e) for e in ev) + "\n")
        w = score.attribute_writes(path)
        self.assertEqual((w["agy"], w["claude_tool"], w["claude_bash"]), (1, 1, 1))
        self.assertEqual(w["between_calls"], 1)
        self.assertEqual(w["gate_blocks"], 1); self.assertEqual(w["blocked_heads"], {"tee": 1})
        self.assertEqual(w["claude_bash_commands"], ["cat x"])
        self.assertEqual(w["pairing"], "tool_use_id")

    def test_toolchain_gomod_change_is_not_a_claude_write(self):
        """A `go` command whose only tree change is go.mod/go.sum is the module tooling (measured with -mod=mod); calling it claude_bash would fake a violation."""
        ev = [
            {"event": "gate", "decision": "allow", "heads": ["go"], "tool_use_id": "a", "command": "go doc x/y"},
            {"event": "PreToolUse", "tool_name": "Bash", "tool_use_id": "a", "head": "go", "fp": "f0", "files": [["go.mod", "aaa"]]},
            {"event": "PostToolUse", "tool_name": "Bash", "tool_use_id": "a", "head": "go", "fp": "f1", "files": [["go.mod", "bbb"], ["go.sum", "ccc"]]},
            {"event": "gate", "decision": "allow", "heads": ["go"], "tool_use_id": "b", "command": "go test ./..."},
            {"event": "PreToolUse", "tool_name": "Bash", "tool_use_id": "b", "head": "go", "fp": "f1", "files": [["go.mod", "bbb"]]},
            {"event": "PostToolUse", "tool_name": "Bash", "tool_use_id": "b", "head": "go", "fp": "f2", "files": [["go.mod", "bbb"], ["x.go", "ddd"]]},
            {"event": "PreToolUse", "tool_name": "Bash", "tool_use_id": "c", "head": "agy-delegate", "fp": "f2", "files": []},
            {"event": "PostToolUse", "tool_name": "Bash", "tool_use_id": "c", "head": "agy-delegate", "fp": "f3", "files": [["y.go", "eee"]]},
        ]
        path = _write(os.path.join(self.tmp, "t2.jsonl"), "\n".join(json.dumps(e) for e in ev) + "\n")
        w = score.attribute_writes(path)
        self.assertEqual(w["toolchain_gomod"], 1)
        self.assertEqual(w["claude_bash"], 1); self.assertEqual(w["claude_bash_files"], ["x.go"])
        self.assertEqual(w["agy"], 1); self.assertEqual(w["agy_files"], ["y.go"])

    def test_rerun_groups_by_package_and_top_level_test(self):
        """Subtests collapse to their parent; packages are rerun separately."""
        g = score.rerun_groups(["a/b.TestX/sub1", "a/b.TestX/sub2", "a/b.TestY", "c/d.TestZ"])
        self.assertEqual(g, {"a/b": ["TestX", "TestY"], "c/d": ["TestZ"]})

    def test_vet_findings_drop_line_numbers(self):
        """An inherited finding must still match after an edit shifts its line."""
        a = score.vet_findings("lib/x.go:146:18: the cancel function should be called\n# pkg\n")
        b = score.vet_findings("lib/x.go:150:18: the cancel function should be called\n")
        self.assertEqual(a, b); self.assertEqual(a, ["lib/x.go: the cancel function should be called"])

    def test_write_attribution_falls_back_to_sequence(self):
        ev = [
            {"event": "PreToolUse", "tool_name": "Bash", "head": "agy-delegate", "fp": "f0"},
            {"event": "PostToolUse", "tool_name": "Bash", "head": "agy-delegate", "fp": "f1"},
        ]
        path = _write(os.path.join(self.tmp, "t.jsonl"), "\n".join(json.dumps(e) for e in ev) + "\n")
        w = score.attribute_writes(path)
        self.assertEqual(w["pairing"], "sequence"); self.assertEqual(w["agy"], 1)

    def test_size_class_boundaries(self):
        self.assertEqual(common.size_class(99), "small"); self.assertEqual(common.size_class(100), "medium")
        self.assertEqual(common.size_class(600), "medium"); self.assertEqual(common.size_class(700), "large")

    def test_is_test_path(self):
        for p in ("a/b_test.go", "pkg/testdata/x.txt", "acceptance/testdata/t.txtar", "pkg/integration/tests/x/y.go"):
            self.assertTrue(common.is_test_path(p), p)
        for p in ("a/b.go", "cmd/test/main.go", "internal/testing.go"):
            self.assertFalse(common.is_test_path(p), p)


if __name__ == "__main__":
    unittest.main()
