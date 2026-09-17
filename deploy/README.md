# Deploying for an organisation

Two files, one bundle. The **server** is declared in `managed-mcp.json` so its settings
are the organisation's; the **Conductor side** (skill, hooks, commands, subagent) is the
plugin, force-enabled from managed settings.

## For the security review — three lines

- **What is read:** text files under the selection `root`, and only under
  `DELEGATION_ALLOWED_ROOTS` when set — after `.gitignore`, a built-in ignore list
  (secrets, lockfiles, build output), binary/media detection and redaction of
  credential-shaped strings. The server never writes.
- **Where it is sent:** only to hosts matching `DELEGATION_ALLOWED_HOSTS`. Default:
  `*.googleapis.com`, `*.gateway.dev` (Google's managed endpoints). A request to any other
  host is refused before anything is sent. Every response names the destination host.
- **Who controls it:** `managed-mcp.json` and managed settings, deployed by the
  organisation (MDM / GPO / config management). A developer cannot widen the allowlist,
  move the alias table, or change the driver from their own machine.

## Files

- `managed-mcp.json` → `/Library/Application Support/ClaudeCode/managed-mcp.json` (macOS),
  `/etc/claude-code/managed-mcp.json` (Linux/WSL), `C:\Program Files\ClaudeCode\managed-mcp.json`.
  The sample is the recommended **Vertex passthrough** topology: the vertex driver with
  `DELEGATION_GATEWAY_BASE_URL` pointing at a transparent proxy the organisation runs in
  front of Vertex AI (IAM, per-caller quota, logging to BigQuery). Terraform for that proxy
  is in the server repository under `deploy/gateway-vertex-passthrough/`; its output
  `gateway_host` fills every `<gateway-host>` above — the host must appear in
  `DELEGATION_ALLOWED_HOSTS`, because `*.run.app` is deliberately not in the default.
  Without a proxy, drop the three `DELEGATION_GATEWAY_*` lines: the server talks to Vertex
  AI directly and writes usage to Cloud Logging in the project.
- `managed-settings.json` → the managed settings file for the same paths. It force-enables
  the plugin, restricts MCP servers to managed ones, and pre-approves the tools under both
  names they can carry: `mcp__delegation__*` (a server named `delegation` in
  `managed-mcp.json`) and `mcp__plugin_antigravity_delegation__*` (the copy bundled in the
  plugin, if it is allowed to start).

## Binary placement

`/opt/delegation-mcp/server/{index.js,prices.json,VERSION}` is the same bundle the plugin
ships in `server/`. Copy it from a plugin checkout or from a `gemini-studio-mcp` release
(`scripts/sync-server.sh --release <tag>` in this repository fetches and verifies one).
Node.js 20+ at `/usr/local/bin/node` (adjust `command`).

## Compatibility mode instead of passthrough

If an OpenAI-style gateway is already in place (Google API Gateway model routing, or a
LiteLLM-class gateway), replace the three `DELEGATION_GATEWAY_*` lines with:

```
"DELEGATION_GATEWAY_DRIVER": "openai-compat",
"DELEGATION_GATEWAY_URL": "https://<gateway>/v1",
"DELEGATION_GATEWAY_AUTH": "bearer-env",
"DELEGATION_GATEWAY_BEARER_ENV": "ORG_LLM_GATEWAY_TOKEN"
```

and add the gateway's host to `DELEGATION_ALLOWED_HOSTS` if it is not under `*.gateway.dev`
(a custom domain on API Gateway needs an entry). The alias is sent as the model name; the
gateway's routing table decides. Context caching, batch and audio/video are Vertex
features and are not available on this path.

## Roles on the passthrough project

The proxy's service account needs `roles/aiplatform.user` (and `roles/storage.objectAdmin`
on the staging bucket when `staging_mode = proxy-gcs`); developers need `roles/run.invoker`
on the proxy service and nothing on Vertex AI. Direct mode instead needs
`roles/aiplatform.user` per developer, plus `roles/logging.logWriter` for Cloud Logging
usage records.
