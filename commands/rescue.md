---
description: Offload a debugging, build, or test failure to Antigravity (Gemini Pro) to repair.
argument-hint: "[scope: paths or tests] <error message or description>"
---

Delegate a debugging or repair task to Antigravity (`agy` / Gemini) under cost discipline,
using Gemini Pro's deep reasoning capabilities to fix a failure.

Task/Failure: $ARGUMENTS

Do this:
1. Capture the failure context (such as compiler errors, stack traces, test logs, or files).
2. Delegate the repair to agy (pro tier) with direct write permissions enabled (`--yolo`):
   `agy-delegate --tier pro --dir . --yolo "Repair the following issue: $ARGUMENTS"`
3. Verify the edits: compile, run tests, or lint the code. Do not trust a self-reported "done".
4. Present the verified changes, the diff, and the verification output.
