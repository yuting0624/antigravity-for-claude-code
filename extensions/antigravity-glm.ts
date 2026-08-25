/**
 * antigravity-for-glm-code — pi extension.
 *
 * Ports this plugin's former Claude Code hooks onto pi's event system and makes
 * the delegation wrappers callable as native tools:
 *
 *   - session_start      → fast health check: brain (GLM/ZAI), agy CLI, local executor
 *   - before_agent_start → injects the COST-AWARE routing policy once per session,
 *                          and appends a fixed advisory nudge when a prompt looks like
 *                          bulk work above the delegation break-even (EN/中文/JA)
 *   - registered tools   → `delegate` (scripts/agy-delegate.sh — unified agy|local
 *                          entry point) and `job` (scripts/agy-job.sh, background jobs)
 *
 * The wrappers own ALL delegation semantics (exit codes, AGY_SIGNAL/LOCAL_SIGNAL,
 * digest contracts); this extension is a thin, path-resolving bridge so the agent
 * never needs plugin binaries on PATH (pi does not put packages on PATH).
 *
 * Toggles (env, legacy CLAUDE_PLUGIN_OPTION_* names still honored):
 *   AGY_OPTION_CODING_POLICY=off     suppress the routing-policy injection
 *   AGY_OPTION_DELEGATION_NUDGE=off  suppress the bulk-work nudge
 */
import { spawn, spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";

const HERE = dirname(fileURLToPath(import.meta.url)); // <pkg>/extensions (single-file extension)
const PKG_ROOT = join(HERE, "..");
const DELEGATE_SH = join(PKG_ROOT, "scripts", "agy-delegate.sh");
const JOB_SH = join(PKG_ROOT, "scripts", "agy-job.sh");

const HARD_KILL_MS = 40 * 60 * 1000; // wrappers manage their own timeouts; this is a backstop

function opt(name: string): string | undefined {
  const v = process.env[`AGY_OPTION_${name}`] ?? process.env[`CLAUDE_PLUGIN_OPTION_${name}`];
  return v === "" ? undefined : v;
}
function isOff(name: string): boolean {
  const v = (opt(name) ?? "").toLowerCase();
  return v === "off" || v === "false" || v === "0" || v === "no" || v === "disabled";
}

/** Run a shell script, capture stdout/stderr/rc. Never throws. */
function runScript(
  script: string,
  args: string[],
  cwd: string | undefined,
): Promise<{ code: number; stdout: string; stderr: string }> {
  return new Promise((resolve) => {
    let stdout = "";
    let stderr = "";
    const child = spawn(script, args, { cwd, stdio: ["ignore", "pipe", "pipe"] });
    const timer = setTimeout(() => child.kill("SIGKILL"), HARD_KILL_MS);
    child.stdout.on("data", (d) => (stdout += d));
    child.stderr.on("data", (d) => (stderr += d));
    child.on("error", (e) => {
      clearTimeout(timer);
      resolve({ code: -1, stdout, stderr: `${stderr}${e.message}` });
    });
    child.on("close", (code) => {
      clearTimeout(timer);
      resolve({ code: code ?? -1, stdout, stderr });
    });
  });
}

// ---------------------------------------------------------------------------
// Routing policy (injected once per session, mirrors the old policy-context.json)
// ---------------------------------------------------------------------------
const ROUTING_POLICY = `[antigravity-for-glm-code] Routing policy — you (GLM, running in the pi coding agent) conduct; executors execute. This is COST-AWARE delegation, NOT "delegate everything".

EXECUTOR CHOICE:
- agy (Gemini): agentic work — reads/writes repo files (--dir), web + Vertex AI Search, subagent fan-out. Needs the Antigravity CLI.
- local (Ollama/LM Studio/vLLM via OpenAI-compatible API): private, free, offline. Text-in/text-out: no file access (feed via stdin), writes land via --out <file>, search via --web. Default backend when agy is absent.

WHEN to delegate: bulk / parallel / repetitive work that clearly exceeds the spec + round-trip + verify overhead — mass scaffolding, exhaustive test generation, migrations, long-context reads that return a small digest, fan-out search; privacy-sensitive diffs to the local executor. WHEN NOT to: small, self-contained, or judgement-heavy tasks — do them yourself (a delegated tiny task is a measured NET LOSS).

HOW (the cost levers):
- Prefer the registered \`delegate\` tool (backend/tier/prompt/digest/dir/out/web options), or run scripts/agy-delegate.sh directly relative to this skill/package. Use the \`job\` tool for long background delegations.
- Keep YOUR context LEAN (biggest lever): take a DIGEST; never re-read files an executor handled or paste its raw output into the thread.
- agy repo work: pass dir <repo-root> so it reads AGENTS.md + real files. Batch one big delegation over many small ones. Review the diff, not the whole tree.
- Headless/print mode (pi -p): delegate SYNCHRONOUSLY — there is no later turn to collect a backgrounded result.

VERIFY (non-negotiable): never trust an executor's self-reported "GREEN" — actually run the gate yourself in a clean state. agy has been observed altering its own environment (patching installed packages, mock-stubbing deps) to force a pass. You own correctness.`;

const NUDGE = `[antigravity-for-glm-code] This prompt looks like BULK work (mass edits / migration / exhaustive tests / fan-out search) — possibly above the delegation break-even. CONSIDER routing the bulk part to an executor (the delegate tool; backend agy for agentic repo work, backend local for private generation). Then verify its digest. THE JUDGMENT IS YOURS: if the task is actually small, self-contained, or judgement-heavy, do it yourself — delegating below the break-even is a measured net loss. Decide silently; don't mention this notice.`;

const BULK_PATTERNS = [
  // EN
  "all files", "every file", "across the codebase", "entire codebase", "whole repo",
  "migrate", "migration", "generate tests", "test coverage", "exhaustive test",
  "scaffold", "boilerplate", "deep research", "web search",
  // 中文
  "所有文件", "全部文件", "整个代码库", "整个仓库", "全仓", "批量", "全量",
  "迁移", "生成测试", "测试用例", "覆盖所有", "脚手架", "样板代码", "深度调研",
  "全网搜索", "联网搜索",
  // JA
  "一括", "全ファイル", "すべてのファイル", "網羅", "移行", "大量", "横断", "リポジトリ全体",
];

function looksLikeBulk(prompt: string): boolean {
  const p = prompt.toLowerCase();
  return BULK_PATTERNS.some((k) => p.includes(k));
}

function looksAlreadyDelegating(prompt: string): boolean {
  return /agy-delegate|local-delegate|agy-job|antigravity|delegate\s+tool/i.test(prompt);
}

// ---------------------------------------------------------------------------
// Fast health check (no long-running network calls)
// ---------------------------------------------------------------------------
async function healthCheck(): Promise<string> {
  const lines: string[] = [];

  // brain
  if (process.env.ZAI_CODING_CN_API_KEY) lines.push("brain: GLM (ZAI Coding Plan 中国区) ✓");
  else if (process.env.ZAI_API_KEY) lines.push("brain: GLM (ZAI Coding Plan Global) ✓");
  else {
    try {
      const mj = JSON.parse(
        readFileSync(join(process.env.HOME ?? "~", ".pi", "agent", "models.json"), "utf8"),
      );
      const providers = Object.keys(mj?.providers ?? {});
      const glmish = providers.filter((p) => /glm|zai|zhipu|bigmodel/i.test(p));
      lines.push(
        glmish.length > 0
          ? `brain: 自定义 Provider（${providers.join(", ")}）——含疑似 GLM 端点`
          : `brain: 自定义 Provider（${providers.join(", ") || "无"}）`,
      );
    } catch {
      lines.push(
        "brain: 默认 Anthropic 端点 —— 切换到 GLM：pi /login 选 ZAI Coding Plan (China)，或在 ~/.pi/agent/models.json 加 anthropic-messages 端点",
      );
    }
  }

  // agy executor
  const agy = spawnSync("bash", ["-c", "command -v agy >/dev/null 2>&1 && echo yes || echo no"]);
  lines.push(
    agy.status === 0 && agy.stdout.toString().trim() === "yes"
      ? "agy 执行器: 已安装 ✓"
      : "agy 执行器: 未安装（委派将自动回落本地执行器；安装见 antigravity.google/docs/cli-using）",
  );

  // local executor
  const base = (
    process.env.LOCAL_DELEGATE_BASE_URL ??
    process.env.CLAUDE_PLUGIN_OPTION_LOCAL_BASE_URL ??
    "http://127.0.0.1:8000/v1"
  ).replace(/\/$/, "");
  try {
    const res = await fetch(`${base}/models`, { signal: AbortSignal.timeout(2000) });
    lines.push(`本地执行器: ${base} 可达 ✓`);
    void res;
  } catch {
    lines.push(
      `本地执行器: ${base} 不可达（ollama serve / LM Studio Server 未启动？不影响其它功能）`,
    );
  }
  return lines.join("\n");
}

// ---------------------------------------------------------------------------
// Extension entry
// ---------------------------------------------------------------------------
export default function antigravityGlm(pi: ExtensionAPI) {
  let policyInjected = false;

  pi.on("session_start", async (_event, ctx) => {
    policyInjected = false; // new/resumed session: inject again on next turn
    if (!ctx.hasUI) return;
    try {
      const report = await healthCheck();
      ctx.ui.notify(`[antigravity-for-glm-code]\n${report}`, "info");
    } catch {
      /* health check must never block startup */
    }
  });

  pi.on("before_agent_start", async (event, _ctx) => {
    let systemPrompt = event.systemPrompt;
    if (!isOff("CODING_POLICY") && !policyInjected) {
      systemPrompt += `\n\n${ROUTING_POLICY}`;
      policyInjected = true;
    }
    if (!isOff("DELEGATION_NUDGE") && looksLikeBulk(event.prompt) && !looksAlreadyDelegating(event.prompt)) {
      systemPrompt += `\n\n${NUDGE}`;
    }
    if (systemPrompt !== event.systemPrompt) return { systemPrompt };
    return undefined;
  });

  pi.registerTool({
    name: "delegate",
    label: "Delegate to executor",
    description:
      "Delegate ONE well-scoped unit of work to an executor under cost discipline. " +
      "backend 'agy' (Gemini via the Antigravity CLI) does agentic work: reads/writes repo files (pass dir), terminal, web search. " +
      "backend 'local' (Ollama/LM Studio/vLLM, OpenAI-compatible) is private/free/offline but is a plain chat completion: no file access (put content in the prompt), generated files land via out. " +
      "Only delegate ABOVE the break-even: bulk, parallel, repetitive work. Returns the executor's reply/digest — YOU must verify the result yourself.",
    parameters: Type.Object({
      prompt: Type.String({ description: "The task for the executor. For reads/analysis end with a request for a compact DIGEST." }),
      backend: Type.Optional(Type.String({ description: "'agy' | 'local' | 'auto' (default auto: agy if installed, else local server)" })),
      tier: Type.Optional(Type.String({ description: "agy: flash|flash-lo|pro (default flash). local: fast|think (aliases map automatically)" })),
      model: Type.Optional(Type.String({ description: "Exact model name overriding the tier mapping" })),
      dir: Type.Optional(Type.String({ description: "(agy) workspace directory so the executor reads real files + AGENTS.md" })),
      yolo: Type.Optional(Type.Boolean({ description: "(agy) approve ALL tools — needed for web search / terminal / uncovered writes. Run write tasks on a branch" })),
      digest: Type.Optional(Type.Boolean({ description: "Append a digest-only output contract (recommended for any analysis/read task)" })),
      out: Type.Optional(Type.String({ description: "(local) write the reply to this file (single outer code fence unwrapped)" })),
      web: Type.Optional(Type.String({ description: "(local) set to any value to fetch search results first (SearXNG or DuckDuckGo) as citable context" })),
      timeout: Type.Optional(Type.String({ description: "e.g. 10m (agy default 5m, local default 10m)" })),
    }),
    async execute(_toolCallId, params, _signal, _onUpdate, ctx) {
      const args: string[] = [];
      if (params.backend) args.push("--backend", params.backend);
      if (params.tier) args.push("--tier", params.tier);
      if (params.model) args.push("--model", params.model);
      if (params.dir) args.push("--dir", params.dir);
      if (params.yolo) args.push("--yolo");
      if (params.digest) args.push("--digest");
      if (params.out) args.push("--out", params.out);
      if (params.web) args.push("--web");
      if (params.timeout) args.push("--timeout", params.timeout);
      args.push(params.prompt);
      const r = await runScript(DELEGATE_SH, args, ctx.cwd);
      let text = r.stdout.trim();
      const errLines = r.stderr.split("\n").filter(Boolean).slice(-6).join("\n");
      if (r.code !== 0) {
        text += `\n\n[delegate failed: exit ${r.code}]\n${errLines}\nExit codes: 10 quota · 11 auth · 12 timeout · 13 executor missing · 14 model unavailable · 15 permission denied (agy only — add a permissions.allow rule or --yolo; soft deny since agy 1.1.3 and hard error since agy 1.1.13 both land here).`;
      } else if (errLines) {
        text += `\n\n[note] ${errLines}`;
      }
      if (!text) text = `(empty reply, exit ${r.code})`;
      return { content: [{ type: "text", text }], details: {} };
    },
  });

  pi.registerTool({
    name: "job",
    label: "Background delegation jobs",
    description:
      "Manage BACKGROUND delegations (interactive sessions only — in print mode delegate synchronously instead). " +
      "action=start launches scripts/agy-job.sh with the given wrapper args and returns a JOB_ID immediately; " +
      "status/result/cancel take an id. Collect results later and verify them.",
    parameters: Type.Object({
      action: Type.String({ description: "start | list | status | result | cancel" }),
      id: Type.Optional(Type.String({ description: "job id (required for status/result/cancel)" })),
      args: Type.Optional(Type.Array(Type.String(), { description: "(start) additional wrapper args, e.g. ['--tier','pro','--dir','.','<task>']" })),
    }),
    async execute(_toolCallId, params, _signal, _onUpdate, ctx) {
      const args: string[] = [params.action];
      if (params.id) args.push(params.id);
      if (params.action === "start" && params.args) args.push(...params.args);
      const r = await runScript(JOB_SH, args, ctx.cwd);
      const tail = r.stderr.split("\n").filter(Boolean).slice(-4).join("\n");
      let text = r.stdout.trim();
      if (tail) text += `\n[stderr] ${tail}`;
      if (r.code !== 0) text += `\n[job exit ${r.code}]`;
      return { content: [{ type: "text", text: text || "(no output)" }], details: {} };
    },
  });
}
