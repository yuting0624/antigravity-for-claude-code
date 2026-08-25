---
description: Health check — the GLM brain, the agy executor, the local executor, and the plugin's wiring.
---

Run the plugin's doctor and report status.

Locate this package's `scripts/` directory (two levels above the `antigravity-glm`
skill directory) and run:

`bash <pkg>/scripts/doctor.sh`

Then summarize for the user:
- **Brain**: is pi running GLM (ZAI Coding Plan via `pi /login`, env `ZAI_CODING_CN_API_KEY`
  or `ZAI_API_KEY`, or a custom `anthropic-messages` provider in `~/.pi/agent/models.json`)?
- **agy executor**: installed, authenticated (can list models), GCP project/region, tier
  models present?
- **local executor**: is an OpenAI-compatible server reachable (default
  `http://localhost:11434/v1`)? Are the configured local models served?
- Plugin: scripts/bin executable?

If anything is missing or failing, give the **exact** command to fix it, e.g.:

- GLM brain: run `pi /login` and pick **ZAI Coding Plan (China)** (国际版选 ZAI Coding
  Plan)，或设置环境变量 `ZAI_CODING_CN_API_KEY=<你的智谱编程套餐 Key>`；也可在
  `~/.pi/agent/models.json` 添加 `api: "anthropic-messages"`、
  `baseUrl: "https://open.bigmodel.cn/api/anthropic"` 的自定义 Provider，然后用
  `/model` 选择 glm 模型。
- agy: install the Antigravity CLI, run `agy` once to authenticate.
- local: `curl -fsSL https://ollama.com/install.sh | sh`（macOS 装 App），
  `ollama pull qwen2.5-coder:7b`，确保 `ollama serve` 在运行——或把
  `LOCAL_DELEGATE_BASE_URL` 指向 LM Studio / llama.cpp / vLLM。
- `chmod +x` 被标记的脚本。

Keep it short and actionable.
