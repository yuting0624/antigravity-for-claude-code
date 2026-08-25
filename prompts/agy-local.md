---
description: Delegate a task to the LOCAL model server (Ollama / LM Studio / llama.cpp / vLLM) — private, free, offline. Generation goes in, text or a file comes out.
argument-hint: "[--tier fast|think] [--model <name>] [--out <file>] [--web] <task>"
---

Delegate the task below to the **local executor** (the `delegate` tool with
backend=local), following the `antigravity-glm` skill's cost discipline and verification
gates. Nothing leaves the machine (except an explicit web fetch); nothing executes; the
model only generates text.

Task: $ARGUMENTS

Capabilities and hard limits — be honest with yourself about them:
- **No file access**: it cannot read the repo. Put the content in the prompt, or pipe a
  file via bash (`cat src/x.py | bash <pkg>/scripts/local-delegate.sh "review this"`).
- **Writes land via `out`**: the wrapper writes the reply to exactly one path you name
  (single outer code fence unwrapped automatically). That is the "execution" path.
- **Search via `web`**: the wrapper fetches results (SearXNG if `LOCAL_SEARXNG_URL` is
  set, else DuckDuckGo Lite) and hands them over as citable context — the model
  synthesizes locally with `[n]` + URL citations.
- **Stateless**: each call is independent; include all needed context in the prompt.

Do this:
1. Pick a tier: `fast` (default; e.g. a 7B coder model) for bulk generation,
   `think` (bigger model) for review/reasoning-heavy text. `model` overrides
   (`ollama list` to see what is served).
2. Call the **`delegate` tool**: backend=local, plus `tier`, `out` (when the reply IS the
   artifact: tests, configs, converted files), `digest` (for analysis tasks), `web`.
3. **Verify** — always: run the generated tests, review the written file, check the
   citations. A local model is the weakest reviewer in the stack; its "pass" is a lead,
   not evidence. Report what you delegated and how you verified it.

When NOT to use this: anything needing repo/file awareness or tool use → use the agy
backend; anything judgement-heavy or small → do it yourself.
