---
description: Ask a fast, lightweight question to Gemini 3.6 Flash for rapid lookups and queries.
argument-hint: "<your question>"
---

Quickly query Gemini 3.6 Flash (Low) for rapid coding assistance, syntax lookups, brief explanations,
or sanity checks. This executes synchronously and bypasses heavier context loading to remain fast and cost-effective.

Question: $ARGUMENTS

Do this:
1. Run a quick, single-turn delegation call to agy (flash-lo tier):
   `agy-delegate --tier flash-lo "$ARGUMENTS"`
2. Render the response directly to the user.
