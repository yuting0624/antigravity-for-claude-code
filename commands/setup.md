---
description: Verify the delegation server is present, authenticated, and pointed where the organisation intends.
---

Run the plugin's doctor and report status.

Run in Bash: `delegation-doctor`

It checks Node.js (20 or newer), the shipped server bundle and its version, then runs
the server's own `health_check`: credentials and project, the active gateway (Vertex AI
directly, a passthrough proxy, or a compatibility-mode gateway), the **egress
allowlist** and whether any configured destination is outside it, which model each alias
actually resolves to, Cloud Logging, and internal search.

Summarise for the user:
- Are credentials in place (Application Default Credentials, or the organisation's
  gateway credential), and which project is in use?
- Where do requests go (the `Gateway` and `Egress` lines), and does every alias answer?
- Anything the server lists under "What to do".

If something is missing or failing, give the **exact** fix: `gcloud auth
application-default login`, the config key, or "ask your administrator" when the setting
is managed. Keep it short and actionable.
