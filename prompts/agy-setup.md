---
description: Verify the Antigravity (agy) CLI is installed and authenticated and the plugin is ready to use.
---

Run the plugin's doctor and report status.

Run: `agy-doctor`

Then summarize for the user:
- Is `agy` installed, and can it list models (i.e. authenticated)?
- Are the plugin scripts executable?
- What GCP project / region / default model is `agy` configured for?

If anything is missing or failing, give the **exact** command to fix it (install agy,
authenticate, `chmod +x` the scripts, etc.). Keep it short and actionable.
