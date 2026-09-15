"""Gate table: every row names the write/exec side channel it closes.

Mutation discipline: deleting any single rule in bench/harness/gates.py or
bench/policy/bash-gate-rules.json must turn at least one BLOCK row green-to-red.
"""
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "harness"))
import gates  # noqa: E402

ALLOW = [
    "go test ./...",
    "go test ./... 2>&1 | head -50",
    "go test -run 'TestFoo|TestBar' -count=1 ./internal/x/ -v",
    "go build ./... && go vet ./...",
    "go build -o /dev/null ./cmd/gh",
    "GOFLAGS=-tags=nobadger,nomysql,nopgx go test -short ./... 2>&1 | tail -20",
    "gofmt -l .",
    "gofmt -d modules/x/y.go | head -40",
    "git status --porcelain && git diff --stat",
    "git --no-pager log --oneline -5",
    "git -C internal show HEAD:go.mod | head",
    "git branch --show-current",
    "ls -la internal/attachments; cat go.mod | head -5",
    "grep -rn 'func Test' internal/x/ | wc -l",
    "rg -n 'idleTimeout' --type go modules/",
    "find . -name '*_test.go' -newer go.mod | head",
    "cd internal/x && go test ./... -run TestFoo",
    "timeout 600 go test ./... -count=1",
    "time go build ./...",
    "go test $(go list ./... | grep -v browser/tests) 2>&1 | tail -30",
    "(cd cmd && go build ./...) && echo done",
    "true; : ; set -o pipefail; go vet ./... 2>/dev/null",
    "echo 'not a redirect > inside quotes' | wc -c",
    "cat file.go  # a trailing comment > with a bracket",
    "sort -u names.txt | uniq -c | sort -rn | head",
    "command -v go && which gofmt",
    "jq '.usage' raw/result.json",
    "sed -n 1,60p modules/x/y.go",
    "sed -n '300,345p' x.go; sed -n '/func newRequest/,/^}/p' x.go",
    "grep -rn 'reverse(' --include=*.go . | head -20; sed -n 1,60p a.go",
]
ALLOW_PLUGIN = [
    "agy-delegate --tier flash --yolo --dir . --timeout 10m 'Create x.go; use > and | and $(not run) in single quotes'",
    'agy-delegate --tier flash --yolo --dir . "double-quoted text with > and | and ; inside"',
    'agy-delegate --tier pro --dir . "review this" 2>&1 | tail -5',
    "agy-job start --tier flash \"task\"",
    "agy-trace --audit 5bcc8537-f3ee-414f-8d45-90f84cf4999b",
]
BLOCK = [
    ("cat <<EOF > f.go\npackage x\nEOF", "heredoc"),
    ("go test ./... && cat > out.txt", "redirection to out.txt"),
    ("go test ./... 2>&1 | tee log.txt", "tee"),
    ("echo hi >> notes.md", "append redirection"),
    ("python3 -c 'open(\"a\",\"w\").write(\"x\")'", "python"),
    ("sed -i '' 's/a/b/' x.go", "sed -i"),
    ("sed -n 's/a/b/w out.txt' x.go", "sed w command"),
    ("sed -n '1p;w f' x.go", "sed w after ;"),
    ("sed 1d x.go", "sed without -n"),
    ("sed -n '1e cat /etc/passwd' x.go", "sed e command"),
    ("sed -n -f script.sed x.go", "sed -f"),
    ("git apply p.diff", "git apply"),
    ("patch -p1 < p.diff", "patch"),
    ("cp a.go b.go", "cp"),
    ("mv a.go b.go", "mv"),
    ("rm -rf internal/x", "rm"),
    ("gofmt -l -w .", "gofmt -w"),
    ("gofmt -w=true .", "gofmt -w="),
    ("git diff --output=p.diff", "git diff --output"),
    ("git diff --output p.diff", "git diff --output split"),
    ("find . -name '*.go' -exec rm {} \;", "find -exec"),
    ("find . -name x -delete", "find -delete"),
    ("go run gen.go", "go run"),
    ("go generate ./...", "go generate"),
    ("go mod tidy", "go mod tidy"),
    ("go get example.com/x", "go get"),
    ("go test -c -o x.test ./...", "go test -c"),
    ("go build -o bin/x ./cmd/x", "go build -o file"),
    ("go test -coverprofile=c.out ./...", "coverprofile"),
    ("go test -exec 'sh -c' ./...", "go test -exec"),
    ("go env -w GOFLAGS=-mod=mod", "go env -w"),
    ("rg --pre cat foo", "rg --pre"),
    ("sort -o names.txt names.txt", "sort -o"),
    ("uniq in.txt out.txt", "uniq output positional"),
    ("tree -o t.txt", "tree -o"),
    ("git -c core.pager='sh -c \"id\"' log", "git -c"),
    ("git --exec-path=/tmp log", "git --exec-path"),
    ("git stash", "git stash"),
    ("git checkout -- .", "git checkout"),
    ("git fetch origin", "git fetch"),
    ("git branch -D main", "git branch -D"),
    ("git grep -O 'x'", "git grep -O"),
    ("curl https://example.com", "curl"),
    ("gh pr view 14179", "gh"),
    ("go test ./... &", "background"),
    ("go test `ls`", "backtick"),
    ("go test $(curl x)", "unallowed substitution"),
    ("echo \"$(cat > f)\"", "substitution inside double quotes"),
    ("GOPROXY=https://proxy.golang.org go test ./...", "GOPROXY assignment"),
    ("export X=1", "export"),
    ("cat < /etc/passwd > out", "input redirect plus output"),
    ("diff <(go list ./...) <(cat x)", "process substitution"),
    ("{ go test ./...; }", "brace group"),
    ("agy -p 'x'", "bare agy"),
    ("agy-delegate --tier flash 'x'", "wrapper without plugin"),
    ("bash -c 'go test'", "bash -c"),
    ("env GOFLAGS=x go test", "env"),
    ("xargs rm < list", "xargs"),
    ("go test ./... | xargs -I{} sh -c 'echo {} > f'", "pipe into xargs"),
    ("timeout 10", "timeout without command"),
    ("set +o noclobber", "set with unknown flag"),
    ("cat 'unterminated", "unterminated quote"),
    ("go test ./... 2>&1 >err.log", "redirect stdout to file after dup"),
]


class GateTable(unittest.TestCase):
    def test_allow(self):
        for cmd in ALLOW:
            d = gates.decide(cmd, plugin=False)
            self.assertTrue(d.allow, "should ALLOW: %r -> %s" % (cmd, d.reason))

    def test_allow_plugin(self):
        for cmd in ALLOW_PLUGIN:
            d = gates.decide(cmd, plugin=True)
            self.assertTrue(d.allow, "should ALLOW (plugin): %r -> %s" % (cmd, d.reason))
            self.assertTrue(any(h.startswith("agy-") for h in d.heads), cmd)

    def test_block(self):
        for cmd, why in BLOCK:
            d = gates.decide(cmd, plugin=False)
            self.assertFalse(d.allow, "should BLOCK (%s): %r" % (why, cmd))
            self.assertTrue(d.reason, "block without a reason: %r" % cmd)

    def test_dup_redirections_survive(self):
        """2>&1, >&2 and /dev/null are the only redirections; drop that clause and these fail."""
        for cmd in ("go test ./... 2>&1", "go vet ./... >&2", "go build ./... >/dev/null 2>&1",
                    "go test ./... 2>/dev/null", "agy-delegate 'x' </dev/null"):
            d = gates.decide(cmd, plugin=True)
            self.assertTrue(d.allow, "%r -> %s" % (cmd, d.reason))

    def test_heads_recorded_for_attribution(self):
        d = gates.decide("cd x && go test ./... | tail -3", plugin=False)
        self.assertEqual(d.heads, ["cd", "go", "tail"])

    def test_denial_text_mentions_the_way_out(self):
        self.assertIn("agy-delegate", gates.DENIAL_TEXT)
        self.assertIn("file tools", gates.DENIAL_TEXT)


if __name__ == "__main__":
    unittest.main()
