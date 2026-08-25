---
name: antigravity-glm
description: 在 GLM 大脑（pi coding agent）下把工作委派给两类执行器的智能模型路由技能：Antigravity CLI（agy/Gemini，具备代理能力——读写文件、联网搜索）或本地 OpenAI 兼容服务（Ollama/LM Studio/omlx/vLLM——私密、免费、离线）。Use when the user wants to delegate work ("use Antigravity / agy", "delegate to a local model", "vibe code / agentic engineering", "scaffold / generate tests / migrate", "first-pass code review", "search web or internal data", "deep research", "second-model cross-check", "keep code private / offline"), accelerate the SDLC, or lower token cost on big jobs — 委派任务、生成测试、代码迁移、首轮评审、深度调研、跨模型交叉验证、降低 token 成本时使用。指挥者始终亲自验证执行器的产出。
version: 0.27.0
---

# Antigravity for GLM Code — 混合式软件开发生命周期

一个指挥者、两类执行器、一条工作流。指挥者就是**你自己——运行在 pi coding agent 里的 GLM（GLM-4.6/GLM-4.5 等）**，通过 pi 内置的智谱 Provider 接入（`pi /login` → ZAI Coding Plan；环境变量 `ZAI_CODING_CN_API_KEY` 为中国区 / `ZAI_API_KEY` 为国际版），或在 `~/.pi/agent/models.json` 里配置指向 `https://open.bigmodel.cn/api/anthropic` 的 `anthropic-messages` 自定义端点。执行器有两类：

- **agy（Antigravity CLI，Gemini）** —— 能力型执行器：完整的终端代理（读写文件、跑终端命令、子代理、MCP、Google/网络搜索 + Vertex AI Search）。
- **local（本机 omlx 引擎 / Ollama / LM Studio / llama.cpp server / vLLM）** —— 私密型执行器：任何 OpenAI 兼容的本机服务。免费、离线、数据不出机器（显式的 `--web` 抓取除外）。本质是一次聊天补全调用——诚实的边界见下文。

核心思想是**跨软件开发生命周期的智能模型路由**：判断密集型的工作留在 GLM 上，确定性的高产量工作下沉给更便宜的执行器。*生成已被解决；验证、判断与方向感才是手艺。*

- **GLM = 指挥者 / 编排者** —— 需求、架构、最难的那 20%（边界情况、集成、正确性）、规格、测试契约、最终评审。
- **agy = 受委派的代理** —— 以代理方式执行规格明确的任务：读仓库、改文件、搜索、内部扇出子代理。
- **local = 受委派的生成器** —— 同一套委托契约，文本进文本出：私密地生成代码/测试/摘要；wrapper 可以代为抓取搜索结果（`--web`）或把回复写入文件（`--out`）。

这是**代理工程，不是凭感觉编码**：价值在于围绕模型的结构——路由、共享规则、验证关卡——而不是原始生成能力。

## 让 GLM 成为大脑

pi 已内置 **ZAI Coding Plan** Provider，三种方式任选其一：

1. `pi /login` → 选 **ZAI Coding Plan (China)**（国际版选 ZAI Coding Plan），然后 `/model` 选择 glm 模型（`pi --list-models zai-coding-cn` 查看 id）；或
2. 启动前设置环境变量：`export ZAI_CODING_CN_API_KEY=<智谱编程套餐 Key>`；或
3. 在 `~/.pi/agent/models.json` 配置自定义 Anthropic 兼容端点：
   ```json
   { "providers": { "glm": {
       "baseUrl": "https://open.bigmodel.cn/api/anthropic",
       "api": "anthropic-messages",
       "models": [ { "id": "glm-4.6" }, { "id": "glm-4.5-air" } ] } } }
   ```

`agy-doctor` 会报告它检测到的当前大脑。

## 两种模式（按任务选择）

- **指挥者模式（同步内联）**：你正在实时打磨某个东西，中途把一个小的、边界清晰的工作块丢给执行器，立即使用结果。
- **编排者模式（异步多单元）**：把更大的任务拆成多个单元并行派发（常配 `--dir` 让 agy 直接读仓库），最后统一评审整合。适合迁移、按模式批量实现、测试套件。

## 跨软件开发生命周期的分工

| SDLC 阶段 | 归属 | 原因 |
|---|---|---|
| 需求与规划 | **GLM** | 歧义消解、与人对话的判断力 |
| 设计与架构 | **GLM** | 权衡取舍 |
| 实现——复杂/承载架构的 20% | **GLM** | 正确性、深层上下文 |
| 实现——脚手架/样板/规格明确的批量活 | **agy 或 local** | 确定性、高产量 |
| 测试与评估生成 | **local**（私密）或 **agy**（GLM 定义契约） | 廉价算力的地盘 |
| 首轮代码评审 | **local**（隐私）或 **agy** → **GLM** 终审 | AI 初筛 + 大脑终审 |
| 跨模型交叉验证 | **≥2 个不同家族的模型** | 不同失败模式互为保险 |
| 维护/迁移/现代化 | **agy** 执行（真实改文件），**GLM** 定方向 | 繁琐、系统化 |
| 网络 / Vertex AI Search | **agy**（原生工具）· **local + `--web`**（自建搜索综合） | 补齐 GLM 缺失的工具 |
| 音频/视频理解 | **agy** 转写+摘要 · **GLM** 核实 | Gemini 原生多模态；本地模型不支持音视频输入 |
| 深度调研（多源） | 执行器扇出搜集 · **GLM** 验证引证并成文 | 重活在廉价侧消化 |

执行器档位：agy —— `flash`（默认，批量）· `flash-lo`（最便宜，琐碎）· `pro`（更难推理/评审/交叉核验）；local —— `fast`（默认）· `think`（更强的本地模型），均可通过选项重映射。

## 如何调用

**首选：扩展注册的原生工具**（本包的 pi 扩展提供）：

- `delegate` 工具 —— 参数：`prompt`（任务）、`backend`（'agy' | 'local' | 'auto'）、`tier`、`model`、`dir`、`yolo`、`digest`、`out`、`web`、`timeout`。内部运行 `<包目录>/scripts/agy-delegate.sh`——两个执行器的统一入口。
- `job` 工具 —— 后台委派管理（action=start / list / status / result / cancel）。仅交互式会话可用。

通过 bash 等价调用（`<pkg>` = 本技能目录的上两级）：

```bash
bash <pkg>/scripts/agy-delegate.sh --backend agy   --tier pro --dir ./app --yolo "..."
bash <pkg>/scripts/agy-delegate.sh --backend local --tier think "... "
bash <pkg>/scripts/local-delegate.sh --tier fast --out ./tests/test_x.py "..."
```

斜杠命令：`/agy-delegate`、`/agy-local`、`/agy-review`、`/agy-research`、`/agy-setup`、`/agy-status` … 展开即得现成的工作流。

共用参数：`--tier …` · `--model <确切名称>` · `--digest`（附加"仅摘要"输出契约——任何读取/分析类任务都该加；两种 wrapper 都会在回复大到像原始倾倒时于 stderr 发警告）· `--timeout 10m` · `--print-command`（干跑）· 结尾 `-` 表示从 stdin 读长提示词。

仅 agy：`--dir <路径>`（工作区，可重复——agy 据此读 AGENTS.md 与真实文件）· `--yolo`（自动批准 **全部** agy 工具——最粗的授权；联网 / Vertex AI Search / 终端类工具需要它，未被 permissions.allow 规则覆盖的写入也需要。写任务请开分支）· `--mode accept-edits|plan`（`accept-edits` 不是无头写授权——实测在 agy 1.1.13 上与不加一样被拒）· `--sandbox`（并非隔离手段——实测在 `--yolo` 下毫无作用）· `-c`/`--continue`。

仅 local：`--host <地址>`（默认本机 omlx 引擎 `http://127.0.0.1:8000/v1`）· `--out <文件>`（wrapper 把回复写入指定文件——自动剥除最外层代码围栏，`--raw` 保留原样；**这就是本地的"执行"路径**）· `--web`（wrapper 先抓取搜索结果——设置了 `LOCAL_SEARXNG_URL` 时查你的 SearXNG，否则 DuckDuckGo Lite——作为带编号的可引证上下文交给本地模型）。

**本地执行器的诚实边界**（它是一次聊天补全，不是代理）：
- 无文件访问：读不了 `--dir` 和仓库。内容走 stdin（`cat file | ... -`）或直接粘进提示词；需要代理式操作就换 agy 后端。
- 不能执行任何东西：只返回文本。`--out` 由 wrapper 代写，期间没有任何东西被执行。
- 无记忆：每次调用独立——把所需上下文完整放进提示词。
- 模型质量由你选择：按任务匹配所服务的模型（本机 omlx 默认 `Ornith-1.5-35B-A3B-MLX-4bit` 见 `--print-command` 或 doctor 输出）；7B 级别的小模型干不了架构活。

**结构化失败。** 两种 wrapper 共用退出码：`10` 配额 · `11` 认证 · `12` 超时 · `13` 执行器缺失（agy 未安装 / 本地服务不可达）· `14` 模型不存在（agy：不在 `agy models` 中；local：服务上没有该模型——`ollama pull` 或改档位映射）· `15` 权限被拒（仅 agy：无头模式下某工具需要授权——agy 1.1.3 的软拒绝与 1.1.13 引入的硬错误都归到这里；修法是加 `permissions.allow` 规则或传 `--yolo`）（此外 `2` 失败 / `3` 空输出）。stderr 会输出机器可读的 `AGY_SIGNAL {...}` / `LOCAL_SIGNAL {...}` 行；`job` 工具的 status/result 会转述它们，让你可以直接应对而不是解析散文。

**如果你自己在无头模式运行（`pi -p`，一次性）：** 必须**同步**委派——让 wrapper 阻塞返回后再继续。没有"稍后的回合"来收割后台结果。（`job` 工具只适用于会被再次唤醒的交互式会话。）

## 共享约定：一份 AGENTS.md 管所有 AI

agy **会读取工作区的 `AGENTS.md`**（已验证）。在仓库根维护一份共享的 `AGENTS.md`（技术栈、规范、硬规则、工作流），让指挥者与 agy 在**同一套规则**下工作——这能提升首过率并保持输出一致（降低运维成本）。本地执行器读不了文件——重要规则直接写进它的提示词。

**规则：凡是让 agy 处理仓库工作的委派，务必传 `--dir <仓库根>`**，让它加载 AGENTS.md 与真实代码，而不是把文件粘进提示词（更便宜、上下文更致密）。

## 验证关卡（不可协商）

指挥者对正确性负全责。凡是要交付的东西：

1. **先定义契约。** 测试与评估由你编写并持有——它们比自然语言更精确地告诉执行器"什么叫做对"。
2. **输出评估 = 真的去跑，而不是读完代码就算。** 读 diff 是必要条件而非充分条件——"看起来对"的静态评审仍然是凭感觉。执行它：跑测试、起服务、打真实接口，对照观察到的行为逐条核对验收标准。外部假设要实证核查（比如这个 API 真的接受这种输入吗？）。跑不了就明说——不许标记关卡通过。
3. **轨迹核查（agy）**——路径合理吗？（局限：print 模式只回传最终文本。每次运行都会留下可读轨迹：`~/.gemini/antigravity-cli/brain/<conversationId>/transcript.jsonl`；`agy-delegate` 在用量行里打印 conversationId，成本与轨迹一一对应。用 **`agy-trace --audit <conversationId>`** 审计：步骤类型计数 + 所有非零退出。实测存在整体报 SUCCESS 而内部 6 条命令失败的案例。未记录的内容是命令字符串本身——要把文件系统变化归因到命令，请 diff 目录树。）本地执行器没有轨迹（它只做了一次模型调用），直接验证产物即可。
4. **逐行评审要交付的代码**——警惕聪明代码；核查 import 是否真实存在（幻觉依赖）、错误处理、边界情况，以及契约自身是否自洽（示例/占位符与已验证行为一致）。
5. **绝不相信执行器自报的"全绿"——在干净状态下亲自重跑门禁。** 实测：agy 为了让检查通过会**自己修改环境**——给 site-packages 里已安装的包打补丁、用 MagicMock 顶替缺失依赖——然后报告成功。相信任何通过结果之前：把被动过的工具与干净参照做 diff、还原、在你自己的控制下重跑门禁。自我报告是声明，不是证据。

不对劲时的处置：升档重试（`--tier pro` / `--tier think`）、收紧规格、或者这段干脆自己做。

## 写任务的安全

只读工作（搜索、评审、分析）风险低。**当 agy 要写文件或跑命令时**（`--yolo` 授权写入 + 终端）：
- **写任务需要授权——而且不必是 `--yolo`。** 无头模式下 agy 对"未授权写"的行为随版本漂移——只描述不动手（1.1.0 前）、写去暂存区（1.1.0–1.1.2）、软拒绝（1.1.3 起）、硬错误（1.1.13 起）——但**你的工作区每次都完好无损**，变化的只是它是否承认（上游 issue #10）。wrapper 把两种拒绝形态都映射为退出码 15。**授权有两种，`--yolo` 是粗的那种。** 在 `~/.gemini/antigravity-cli/settings.json` 的 `permissions.allow` 下加一条 `write_file(<目录>)`，即可对该目录**之下递归**生效，完全不需要旗标——经受控 A/B 验证（#37）：覆盖目标成功写入，未覆盖目标返回权限拒绝，唯一变量就是规则。agy 自己的拒绝文案会点名规则并把 `--yolo` 作为替代项。`<目录>` 是占位符：原样留着等于什么都没授权。写任务开专用分支/worktree，用 `git status` 验证。
- **本地执行器**：什么都不执行、什么都不写——除非你通过 `--out <文件>` 亲自动手，而它只会把模型文本写进你指定的那一个路径。不存在需要担心的授权问题，也不需要沙箱。风险只剩内容本身：生成的代码进仓库前照常评审。
- **`--web` 的隐私语义**：查询文本会离开你的机器去搜索引擎（默认 DuckDuckGo；设置 `LOCAL_SEARXNG_URL` 则只经过你自己的 SearXNG）。其余一切（提示词、文档内容、推理）都不出机器。

## 成本纪律 —— 省钱到底从哪来

委派本身**不**省钱。实测事实（上游项目）：小任务上混合方案反而更贵，因为大头是指挥者自己的 `cache_read`——多轮编排中对不断增长的上下文的反复重读。"廉价子代理"承诺的省钱是真的，但只在指挥者上下文精瘦、往返次数少时成立。以下作为硬规则执行：

1. **高于盈亏平衡点才委派。** 只有卸载量明显超过"规格 + 往返 + 验证"开销时才值得。批量/并行/重复（大规模迁移、穷尽测试、扇出调研、长文读取只回小摘要）→ 委派；小、独立、判断密集 → 自己做。（委派小任务是**净亏损**。）本地后端改变了算术：边际 token 成本 ≈ 0 且数据不出机器——权衡变成质量与等待，隐私常常本身就值这个价。
2. **保持指挥者上下文精瘦（最大的杠杆）。** 不要把执行器已经处理过的文件拉回你的上下文，不要把它的大段原始输出粘进对话。吃**摘要**，不吃原文——这才是压垮每轮 `cache_read` 的关键。
3. **让执行器返回摘要而非倾倒。** 每个委派提示词结尾加明确约定，例如：`"...最后用一个 ===DIGEST=== 围栏块收尾：列出改动文件、关键决策、一段'下一步上下文'。冗余细节只落文件，不要出现在回复里。"` 你读 DIGEST；重活留在廉价的执行器侧。
4. **合批，别碎嘴。** 一次大的、规格完整的委派胜过多次小往返。实测（上游）：每次调用都是独立会话、共享不了缓存——对同一语料委派 7.3 次就要付 7.3 次摄取费，盈亏平衡约 5.7 次。相关单元合并为**一次**委派；`--continue` 不是省钱手段（实测续跑比新开贵 +82%/+277%）——它是配额/超时失败后的恢复手段。
5. **评审看 diff，不看整棵树。** `git diff` 紧凑；通读每个文件不是。
6. **不对称投入。** 协调 + 验证不需要开满推理强度；把产量交给便宜的执行器。

对任何成本声明的诚实表述：**不存在统一的 N 倍**。低于盈亏平衡点混合方案更贵；高于它，精简上下文的路由能按实测幅度削减旗舰模型的支出。引用实测数字与盈亏平衡点，永远不要引用头条倍率。

## SDLC 配方

（配方中的 `agy-delegate` 代表 `<pkg>/scripts/agy-delegate.sh`，或等价地用 `delegate` 工具传对应选项。）

```bash
# 从规格搭脚手架（规格/架构由 GLM 写好）——代理式，真实写文件
agy-delegate --backend agy --tier pro --yolo --dir ./app \
  "Scaffold per ARCHITECTURE.md: dirs, configs, stub modules. Follow AGENTS.md."

# 私密地在本地模型上生成测试；wrapper 落盘
cat src/payments.py | local-delegate --tier fast --out ./tests/test_payments.py \
  "为此模块编写 pytest 单元测试与边界用例；只输出 Python 代码"

# 首轮评审（终审在 GLM）——本地保隐私，diff 不出机器
git diff | local-delegate --tier think - \
  "审查此 diff 的正确性/安全/性能问题，保持怀疑。逐条 file:line — 问题"

# 实现到测试通过（反馈循环；开分支隔离）——仅 agy 能做
agy-delegate --backend agy --tier pro --yolo --dir ./app \
  "Implement feature X to satisfy AGENTS.md and make 'pytest -q' pass. Iterate until green."

# 迁移 / 现代化
agy-delegate --backend agy --tier pro --yolo --dir ./svc \
  "Migrate all callers from APIv1 to APIv2 per MIGRATION.md. List every file changed."
cat old_config.yaml | local-delegate --tier think --out new_config.yaml \
  "把这份配置转换成 v2 schema；只输出 YAML"

# 网络搜索 → GLM 复核
agy-delegate --backend agy --tier pro --yolo "Use web search for <X>. Give URLs + dates."
agy-delegate --backend local --tier fast --web "Search: <X>. Cite [n] + URL per finding."

# 音频/视频/图片理解（只有 agy 能做——Gemini 原生多模态；本地模型不支持）
# agy-media 把完整转录写到文件、只回传时间戳摘要——绝不整段转录进上下文
bash <pkg>/scripts/agy-media.sh ./meeting.wav "decisions and owners"
bash <pkg>/scripts/agy-media.sh ./demo.mp4 --timeout 20m    # 视频：附时间戳 VISUALS/OCR
bash <pkg>/scripts/agy-media.sh ./memo.m4a --convert        # m4a/aiff 先转 wav

# Vertex AI Search 检索内部数据（先发现引擎再检索）——仅 agy
agy-delegate --backend agy --tier pro --yolo "List Vertex AI Search engines (list_engines)."
```

## 内部扇出配方（agy 自己孵化子代理）

agy 内置 `define_subagent` / `invoke_subagent` 工具（1.0.16+ 无头验证可用，1.1.x 复验）。用它把编排者的活下沉一层——协调 token 落在便宜的一侧。必须带 `--yolo`（无头模式下子代理工具需要权限）。每个孵化都会留下可读的 `~/.gemini/antigravity-cli/brain/<conversationId>/transcript.jsonl`；用 `agy-trace <id>` 审计。agy 升级后需重新验证——这块上游变动很快。

```bash
agy-delegate --backend agy --dir . --yolo --digest --timeout 10m \
  "ACTUALLY use your define_subagent and invoke_subagent tools (do NOT simulate).
   Decompose <task> into up to 3 units; for each, define a named specialist then
   invoke it. Wait for ALL, report per-unit results + conversationIds, end with a DIGEST line."
```

## 深度调研配方（多源）

agy 的 CLI **没有内置"深度调研"模式**。深度调研是一套**由指挥者编排的配方**：你规划与验证；执行器廉价地跑腿搜集。经验证的告警：`--print` 模式下 agy 用的是搜索-摘要工具、不能可靠抓取整页——它的引证粗糙；本地 `--web` 的结果是 wrapper 抓取的片段，可按 URL 核对。**绝不交付未经验证的引证。**

1. **规划（指挥者）。** 拆解子问题 + 列出必须验证的关键论断。
2. **扇出抓取（执行器，并行，一问一调）。** 强制紧凑输出，笨重的页面留在执行器侧：
   `agy-delegate --backend agy --tier flash --yolo "Web-search <q>. Return 5–8 bullets with exact URLs + dates. ONLY findings+URLs+dates."`
   或 `agy-delegate --backend local --tier fast --web "Search: <q>. 5–8 bullets, cite [n] + URL."`
3. **深挖关键论断。** 点名 URL；让执行器引用支撑原句，否则回复 NOT SUPPORTED。（agy 能自己打开 URL；本地后端不行——把页面文本粘进提示词给它。）
4. **对抗式验证（指挥者）。** 每条关键论断在 ≥2 个独立域交叉印证；单一/含糊/仅域名级引证视为未验证；核对日期；警惕参数化知识冒充有源事实。
5. **综合（指挥者）。** 只从已验证的发现写出带引证的报告；未获印证的明确标注"未验证"。

## 执行器带来而 GLM 原生没有的能力

agy（内置 Google 工具，无头 `--print` 已验证）：Google/网络搜索 · Vertex AI Search（`list_engines`、`search`）· Cloud Logging · Notebooks · 可视化。无头模式用工具需要 `--yolo`。local：隐私、零边际成本、离线运行、模型任你选（甚至可以在 omlx 上部署 GLM 开源权重，让执行器也是 GLM——全套智谱栈）。

## 经济学（金融杠杆，而非卖点）

把确定性的高产量工作路由出旗舰模型，就是**智能模型路由**：更高的 CapEx（这套外壳）换更低的 OpEx（廉价模型干重活）。在 GLM 编程套餐下，执行器分流保护的是平价配额；本地执行器的边际成本是你的电费。用 `agy-cost-compare` 看单任务 per-token 差距（估算；先核对 `prices.json`），用 `measure-session` 看外壳侧会话成本。

## 前置与限制

- **大脑：** pi 已接 GLM（见上文）；`agy-doctor` 会报告检测结果。
- **agy 执行器：** 安装并认证 Antigravity CLI（`agy models` 能列出 Gemini 模型）；无头委派仅支持 macOS/Linux/WSL（原生 Windows 无 ConPTY 可能挂死——wrapper 有墙钟保护兜底）。
- **local 执行器：** 本机默认对接 **omlx 引擎**（`http://127.0.0.1:8000/v1`，默认模型 `Ornith-1.5-35B-A3B-MLX-4bit`，key 已内置兜底）；也支持 Ollama/LM Studio/vLLM（设 `LOCAL_DELEGATE_BASE_URL` / `LOCAL_DELEGATE_API_KEY` 即可）。依赖 `curl` 与 `python3`。`agy-doctor` 会探测。
- 脚本可执行（`chmod +x scripts/*.sh bin/*`）。
- **WSL：** 仓库放在 Linux 文件系统（`~`），别放 `/mnt/*`（9p 桥慢 10 倍）。
