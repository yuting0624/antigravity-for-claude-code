<div align="center">

# 🛰️ Antigravity for GLM Code

**GLM 担任大脑，Gemini 与本地大模型担任执行者——在 pi coding agent 里实现跨软件开发生命周期的智能模型路由。**

GLM 负责判断与验收；执行者负责吞吐——繁重的脚手架、测试生成、检索、迁移都路由到更便宜的算力上。

[![License: MIT](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)
![pi package](https://img.shields.io/badge/pi-package-137CFF)
![Brain: GLM](https://img.shields.io/badge/大脑-GLM%20Coding%20Plan-137CFF?logo=chatbot&logoColor=white)
![Executor: Gemini](https://img.shields.io/badge/执行器-agy%2FGemini-4285F4?logo=googlegemini&logoColor=white)
![Executor: Local LLM](https://img.shields.io/badge/执行器-Ollama%20%2F%20LM%20Studio-6E42D6)

</div>

---

> 📖 **完整使用文档请看 [docs/使用指南.md](docs/使用指南.md)** —— 安装配置、双执行器选型、本地模型服务搭建、成本纪律、验证关卡、故障排查，一册在手。
>
> 本项目 fork 自 [yuting0624/antigravity-for-claude-code](https://github.com/yuting0624/antigravity-for-claude-code)（v0.25.1），经历两次改造：
> ① **把大脑从 Claude（Anthropic）换成 GLM**（智谱 GLM Coding Plan）；
> ② **让执行侧支持本地大模型**（Ollama / LM Studio / llama.cpp / vLLM），不再只有 Gemini；
> ③ **宿主外壳从 Claude Code 插件移植为 [pi coding agent](https://github.com/badlogic/pi-mono) 包**（skills + prompts + extension，`pi install` 即用）。

## 💡 核心思路

| | GLM（指挥者 / 大脑） | agy/Gemini（执行器） | 本地模型（执行器） |
|---|---|---|---|
| **职责** | 需求 · 架构 · 最难的 20% · **验证** · 评审 | 脚手架 · 改文件 · 测试生成 · 网络搜索 · 子代理扇出 | 私有文本生成：测试代码 · 配置转换 · 评审初筛 · 语料摘要 |
| **优势** | 判断力 | 有工具的完整终端代理（读写文件、联网） | 免费 · 私密 · 可离线 |

```
你 → pi coding agent（大脑 = GLM，经内置 ZAI Coding Plan Provider 接入）
        ├── backend "agy"   → Antigravity CLI（Gemini）：有代理能力，能读写仓库、联网搜索
        └── backend "local" → 本地 OpenAI 兼容服务（Ollama 等）：纯文本进出，数据不出机器
```

> *生成已被解决；验证、判断与方向感才是手艺。*

## ✨ 它做什么

- **跨 SDLC 的模型路由** —— GLM 保留所有判断性工作；把确定性的高产量工作（脚手架、测试生成、首轮评审、批量迁移）委托给执行器，双方共读同一份 `AGENTS.md`。
- **注册为原生工具的委派** —— 扩展向 pi 注册 `delegate` 与 `job` 工具：GLM 直接调用即可完成委派与后台任务管理，无需插件 PATH。
- **会话级策略注入** —— `before_agent_start` 事件自动注入成本感知的路由策略；批量任务提示词（中/英/日）触发建议性 nudge，判断权始终在指挥者手里。
- **补齐 GLM 原生没有的工具** —— 通过 agy 获得 Google/网络搜索、Vertex AI Search 内部数据检索、Cloud Logging；通过本地 `--web` 获得私有化的搜索综合。
- **本地大模型 = 隐私 + 零边际成本** —— 敏感 diff 的跨模型评审、测试套件生成、语料摘要都可以完全跑在本机；`--out` 让模型生成的代码直接落盘（由 wrapper 写入，不执行任何东西）。
- **听得声音、看得视频** —— `/agy-media` 把感知交给 Gemini（原生多模态），返回带时间戳的摘要，全文转录落盘不占上下文。
- **跨模型交叉验证** —— 用不同模型家族对同一份代码做独立评审，分歧处才值得人再看一眼。

## 🚀 快速开始

详细步骤见 **[docs/使用指南.md](docs/使用指南.md) 第 3 章**，这里是最短路径：

```bash
# ① 安装本包
pi install git:github.com/<you>/antigravity-for-glm-code
# 或开发模式直接加载：
pi -e /path/to/antigravity-for-glm-code

# ② 大脑接 GLM（三选一）
pi /login            # 选 ZAI Coding Plan (China)，再 /model 选 glm-4.6
export ZAI_CODING_CN_API_KEY=<你的智谱编程套餐 Key>     # bigmodel.cn → 编程套餐 → API Key
# 或 ~/.pi/agent/models.json 加 anthropic-messages 自定义 Provider（见使用指南）

# ③ 执行器（至少配一个）
#    a. Gemini 执行器：安装并登录 Antigravity CLI（https://antigravity.google/docs/cli-using）
#    b. 本地执行器：安装 Ollama 并拉一个编码模型
curl -fsSL https://ollama.com/install.sh | sh && ollama pull qwen2.5-coder:7b && ollama serve

# ④ 体检
/agy-setup           # 或命令行运行 bin/agy-doctor
```

## 🧩 斜杠命令（提示模板）

| 命令 | 作用 |
|---|---|
| `/agy-setup` | 健康检查——GLM 大脑、agy 认证、本地服务探活 |
| `/agy-delegate [--backend agy\|local] [--tier …] <task>` | 在成本纪律下把子任务委托给执行器，然后验证 |
| `/agy-local [--tier fast\|think] [--out f] [--web] <task>` | 专门走本地模型的委托（隐私生成 / 写文件 / 本地综合搜索） |
| `/agy-review [--adversarial]` | 跨模型独立评审当前 diff（默认本地后端，diff 不出机器）；GLM 仲裁 |
| `/agy-research <topic>` | GLM 主导的深度调研——执行器跑腿搜集，GLM 验证引证（≥2 来源）后成文 |
| `/agy-media <file>` | 音频/视频/图片理解（agy 独占——Gemini 原生多模态） |
| `/agy-status` · `/agy-result` · `/agy-cancel` | 后台委托任务管理 |
| `/agy-migrate [--apply]` | 把既有 Claude Code 配置迁到 agy（默认 dry-run） |
| `/agy-cloud-debug` | Cloud Run 故障诊断（agy 分析日志 + GLM 定因） |

另有扩展注册的原生工具：`delegate`（同步委派）与 `job`(后台任务)，GLM 无需任何 PATH 配置即可调用。

## 📦 目录结构

```
package.json             pi 包清单（extensions / skills / prompts）
extensions/antigravity-glm.ts   pi 扩展：delegate/job 工具注册 + 策略注入 + 批量任务 nudge + 健康检查
skills/antigravity-glm/  核心策略文档（WHEN + HOW：GLM 如何与双执行器协作）
prompts/                 斜杠命令模板（agy-setup / agy-delegate / agy-local / …）
bin/                     手动 CLI 垫片：agy-delegate · local-delegate · agy-job · agy-doctor · …
scripts/                 实现：local-delegate(本地执行器) · agy-delegate(统一入口) · doctor · …
docs/使用指南.md         ★ 详细中文使用文档
docs/安装.md             ★ 他人下载后的完整安装步骤
docs/EVALUATION.md       ★ GLM + 本地 omlx/Ornith 配合效果实测
docs/TROUBLESHOOTING.md  上游英文排障手册（症状 → 解法）
prices.json              费率配置（引用任何数字前先核对）
tests/run-tests.sh       无依赖测试套件（stub 掉 agy 与 HTTP 服务）
```

## 🤝 致谢与声明

- 架构与大量工程细节来自上游 [antigravity-for-claude-code](https://github.com/yuting0624/antigravity-for-claude-code)（MIT），包括 issue #10/#29/#37 等用实测换来的防护。本分支的全部改动同样以 MIT 发布。
- 社区项目，与 Google、Anthropic、智谱（Zhipu AI）、pi 均无隶属或背书关系。"Antigravity""Gemini""Claude""GLM""pi" 为各自所有者的商标。API/云费用、凭据与数据共享选择由你自己负责。
