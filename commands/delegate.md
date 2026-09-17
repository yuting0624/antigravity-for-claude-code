---
description: Delegate a well-scoped READ of the codebase to the delegation server (digest_codebase / delegate_task) under cost discipline, then verify.
argument-hint: "<question or task> [paths...]"
---

Delegate the following to the `delegation` MCP server, following the `antigravity`
skill's **Cost discipline** and **Verification gates**. The server reads the files with a
long-context model and returns a digest with `file:line` references; the files never
enter this conversation.

Request: $ARGUMENTS

Do this:
1. **Decide the tool.** A question about the code, or orientation in it →
   `digest_codebase({ paths, root, question })`. A deliverable — an inventory, an
   extraction, a comparison, a summary with a defined shape → `delegate_task({ spec,
   paths, root })`. Pass `root` (the repository directory) and the narrowest `paths` that
   contain the answer. If the request would need files *written*, do that part yourself:
   the server never writes.
2. **Run it synchronously** unless the selection is very large or you do not need the
   result before your next step — then pass `async: true`, note the job id, and collect
   with `/antigravity:result <id>` (interactive sessions only; in headless `claude -p`
   there is no later turn, so stay synchronous).
3. **Ingest only the digest.** Do not open the files it already read except the specific
   `file:line` references you need to verify. Keeping the digest and not the corpus in
   context is where the saving comes from.
4. **Verify.** Read `stats.refs_valid_ratio`; open the references behind any claim you
   are about to act on; run or grep to confirm anything load-bearing. Never treat a
   digest as ground truth. Report what you delegated and how you verified it.

Remember the break-even: delegate when the material clearly exceeds the spec +
round-trip + verification overhead — three files or more, or roughly 20k tokens or more.
Small, self-contained or judgement-heavy work is cheaper to do yourself.
