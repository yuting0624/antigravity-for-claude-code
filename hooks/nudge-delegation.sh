#!/usr/bin/env bash
#
# UserPromptSubmit hook: a cheap, deterministic nudge toward delegation when the
# user's prompt LOOKS like bulk work above the delegation break-even.
#
# Design principle: this supplies judgment MATERIAL — the DECISION stays with
# Claude (per the skill's cost discipline). It never forces a delegation and it
# never fires the wrapper itself: full automation is a measured net loss below
# the break-even, so the break-even call must remain a per-task judgment.
#
# Heuristic is powered by an AlphaEvolve-optimized cost-aware classifier
# (F_0.5 = 0.994550, 100% precision / 0 false positives on a 150-task bilingual
# benchmark; logistic sigmoid log-odds model, bilingual Unicode normalization,
# and gating exemption). Runs in <1ms on python3 with standard libraries only.
# The nudge text is a FIXED string — the user's prompt is never echoed back into
# the context (no escaping/injection surface).
#
# Toggle via plugin userConfig `delegation_nudge`
# (env CLAUDE_PLUGIN_OPTION_DELEGATION_NUDGE: off/false/0/no/disabled). Default: on.
#
set -uo pipefail

raw="$(printf '%s' "${CLAUDE_PLUGIN_OPTION_DELEGATION_NUDGE:-on}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
case "$raw" in off|false|0|no|disabled) exit 0 ;; esac

IN="$(cat 2>/dev/null || true)"
[ -n "$IN" ] || exit 0

# If python3 is unavailable, stay quiet (fail open to normal Claude execution).
if ! command -v python3 >/dev/null 2>&1; then
  exit 0
fi

HIT=0
if AGY_NUDGE_INPUT="$IN" python3 - <<'PY'
import json, math, os, re, sys

raw = os.environ.get("AGY_NUDGE_INPUT", "")
try:
    prompt = json.loads(raw).get("prompt", "")
except Exception:
    sys.exit(1)

if not prompt or not isinstance(prompt, str) or not prompt.strip():
    sys.exit(1)

# Already delegating explicitly? Stay quiet.
if re.search(r"\b(?:antigravity|agy-delegate|agy-job|digest_codebase|delegate_task|review_diff|job_status|job_result)\b", prompt, re.IGNORECASE) or "antigravity" in prompt.lower() or "delegation" in prompt.lower():
    sys.exit(1)

def predict_delegation_score(prompt: str) -> float:
    text = prompt.lower()

    # Detect Japanese using Hiragana, Katakana, and Kanji Unicode blocks
    is_japanese = bool(re.search(r"[\u3040-\u30ff\u4e00-\u9faf]", text))

    # Define shared sub-patterns to factorize/reduce the dimensions
    targets = r"(?:file|class|function|method|module|endpoint|test|component|route|service|model|controller|view|template|table|schema|entity|handler|api|code|director(?:y|ies)|folder|subdirectory|subfolder|package|script|program|workflow|job|config|setting)s?"
    ja_targets = r"(?:ファイル|クラス|関数|メソッド|モジュール|エンドポイント|テスト|コンポーネント|ルート|サービス|エンティティ|ハンドラー|コントローラー|モデル|ビュー|テーブル|api|スクリプト|ソース|コード|スキーマ|クエリ|ディレクトリ|フォルダ|パッケージ|プロトコル|プロジェクト|リポジトリ|プログラム)"
    dir_names = r"(?:src|app|lib|components|utils|tests|backend|frontend|server|client|packages|services)"
    languages = r"(?:typescript|ts|python3?|py3?|go|rust|cpp|c\+\+|java|kotlin|swift)"
    new_targets = r"(?:project|app(?:lication)?|repo(?:sitory)?|service|module|website|api|system|tool|script|utility|cli|backend|frontend|workspace|monorepo|stack|boilerplate)"

    # Define positive feature patterns and if they exempt the prompt from gating mechanisms
    positives = [
        # Codebase-wide scope
        (r"\b(?:across|throughout|entire|whole) (?:the )?(?:codebase|repo(?:sitory)?|project|workspace|app(?:lication)?|backend|frontend|server|client|directory|folder)s?\b|"
         r"(?:リポジトリ|プロジェクト|コードベース|ワークスペース|アプリ|アプリケーション|バックエンド|フロントエンド)全体|"
         r"\bmonorepo\b|\bmulti-repo\b|\bmultiple repos(?:itories)?\b|複数のリポジトリ|モノレポ", 3.0, True),
        
        # Multi-file scope
        (rf"\b(?:all|every|each)(?: single)? (?:\w+\s+)?{targets}\b|"
         rf"\b(?:multiple|several|many|across|throughout) (?:\w+\s+)?{targets}\b|"
         rf"\ball of the (?:\w+\s+)?{targets}\b|"
         rf"\bfor all \d+\b|\ball \d+ (?:\w+\s+)?{targets}\b|"
         rf"\b(?:[2-9]|\d{{2,}}) (?:\w+\s+)?{targets}\b|"
         r"\bacross all\b|"
         r"全ファイル|すべてのファイル|全コンポーネント|全サービス|すべてのコンポーネント|すべてのクラス|すべての関数|すべてのメソッド|"
         rf"(?:[2-9２-９]|\d{{2,}})(?:個|つ|件|箇所)?(?:の)?{ja_targets}", 2.6, True),
        
        # Japanese bulk descriptors
        (rf"(?:各|すべての?|全て(?:の)?|全|複数(?:の)?)[^\s、。]{{0,5}}?{ja_targets}", 2.4, True),
        
        # Bulk/batch intent
        (r"\b(?:bulk|batch|mass|everywhere)\b|\b(?:system|project|codebase|repo(?:sitory)?|app(?:lication)?)-wide\b|\bacross the board\b|"
         r"一括|まとめて|横断|網羅|至る所|一斉に|全体[的にを]?|全部|全件", 2.2, True),
        (r"\bglobal (?:find and replace|search and replace)\b|\bfind and replace all\b|一括置換|一括変換", 2.4, True),
        (r"\bfind all (?:usages|instances|references|calls)\b|\bsearch the (?:codebase|repo|repository)\b|全使用箇所|すべての使用箇所|コードベース内を検索|リポジトリ内を検索", 2.2, True),

        # Directory-wide scope
        (rf"\b(?:in|inside|under|across) (?:the )?{dir_names} (?:directory|folder|path|dir|workspace)\b|{dir_names}/|(?:{dir_names}|ソース|ディレクトリ|フォルダ)配下", 1.8, True),

        # Dead code detection / Cleanup
        (r"\b(?:find|detect|remove|clean|cleanup|delete|get rid of) (?:dead|unused|deprecated) code\b|\bunused (?:imports|variables|functions|classes|files|dependencies)\b|"
         r"未使用の?(?:インポート|変数|関数|クラス|ファイル|コード)|デッドコード|不要なコード|コードクリーンアップ", 1.8, True),

        # Run tests / Check suite
        (r"\b(?:run|execute|perform) (?:all |the )?(?:tests?|linter|checks?|build|test suite)\b|\btest suite\b|テスト(?:の)?実行|テストを実行|ビルドを実行", 1.8, True),

        # Migration intent
        (rf"\bmigrat(?:e|ion|ing)\b|\b(?:convert|port|rewrite|upgrade|move|switch)(?:ing)? (?:all |the )?(?:code|files|project)? (?:to|in|over to) {languages}\b|移行|マイグレーション|ts化|typescript化|python化|移行する", 2.4, False),
        
        # Test generation
        (r"\b(?:generate|write|add|create|implement|provide|make) (?:unit|integration|exhaustive|end-to-end|e2e|regression)?\s*tests?\b|\btest coverage\b|テストコード作成|テスト生成|テストの追加|単体テストの作成|単体テスト追加|テスト自動化|テストを(?:追加|作成|実装|ジェネレート)", 2.2, False),
        
        # Scaffold / setup / New project
        (rf"\bscaffold\b|\bboilerplate\b|\bbootstrap\b|\binitiate project\b|\bsetup project\b|"
         rf"\b(?:create|setup|initialize|start|scaffold|bootstrap|build|generate|make) (?:a )?(?:new )?(?:\w+ )?{new_targets}\b|"
         rf"\bfrom scratch\b|"
         r"雛形|テンプレート生成|プロジェクトの?立ち上げ|新規プロジェクト|新規作成|新規開発|プロジェクトの?作成|環境構築|初期化|スクリプト作成|ツール作成|新規スクリプト|新規ツール|イチから|ゼロから", 2.0, True),
        
        # Deep research / security audit
        (r"\b(?:deep research|web search|investigat(?:e|ion))\b|調査|リサーチ|原因究明|調査・分析", 1.8, True),
        (r"\baudit\b|\bsecurity scan\b|\bvulnerability\b|\bpenetration test\b|脆弱性診断|セキュリティ解析|監査|脆弱性対策", 1.8, True),
        
        # Broad Refactoring
        (r"\b(?:refactor|restructure|rewrite|redesign|overhaul|revamp)\b|リファクタ(?:リング)?|再構築|コードクリーンアップ|クリーンアップ|モダン化|近代化|オーバーホール|刷新", 1.5, False),

        # Infrastructure / CI/CD
        (r"\b(?:terraform|kubernetes|k8s|ci/cd|github actions|workflows|dockerize|docker-compose|ansible|cloudformation)\b|docker化|ci/cd設定|ワークフロー(?:の)?構築|インフラ構築|デプロイ設定", 1.8, True),

        # Dependency updates
        (r"\b(?:upgrade|update|bump) (?:dependencies|packages|librar(?:y|ies)|versions?)\b|\bupgrade all\b|\bpackage updates?\b|依存関係の(?:アップグレード|更新)|ライブラリの(?:アップデート|更新)", 1.8, False),

        # Translation / Internationalization
        (r"\b(?:i18n|internationali[zs]ation|internationali[zs]e|localiz[zs]ation|localiz[zs]e|translation|translate|multi-language|multilingual)\b|多言語化|国際化|翻訳", 1.8, False),

        # Optimization
        (r"\b(?:optimiz(?:e|ation)|profiling|speed up|improve performance|performance improvement|performance tuning)\b|最適化|高速化|パフォーマンス改善|チューニング", 1.4, False),

        # Code Formatting / Linting
        (r"\blint\b|\bprettier\b|\bformat code\b|\bformatting\b|\bautofix\b|\b(?:eslint|stylelint|flake8|black|ruff|pyupgrade)\b|コード整形|フォーマット|静的解析", 1.4, False),
        
        # Automation intent
        (r"\bautomat(?:e|ion|ed)\b|自動化|自動で", 1.5, True),

        # 1.0: bulk READING — orientation, tracing, inventories across many files. Delegating
        # the read is the point of the delegation server, so a question with repository
        # scope is a candidate, not a reason to stay quiet.
        (rf"\b(?:trace|map out|walk (?:me )?through|orient(?:ate)? me|overview of|architecture of|inventory of|catalog(?:ue)? of|enumerate)\b|"
         rf"\b(?:how|where|what|which)\b.{{0,60}}\b(?:across|throughout|in) (?:the |this |our )?(?:codebase|repo(?:sitory)?|project|services?|modules?|packages?|monorepo|tree|system)\b|"
         rf"\b(?:every|all|each) (?:place|location|spot|site|call ?site|usage|reference|occurrence|instance|caller|consumer)s?\b|"
         rf"\bdata flow\b|\bcall (?:graph|chain)\b|\bend[- ]to[- ]end\b|\bsummari[sz]e (?:the |this )?(?:change|diff|pull request|pr|service|module|codebase|repo)\b|"
         r"全体像|構造を把握|データフロー|呼び出し(?:元|先)を?(?:すべて|全部|洗い出|一覧)|どこで.{0,20}(?:読|使|定義|設定|呼)(?:され|われ|まれ|ばれ)|棚卸し|一覧化|洗い出|把握したい", 3.0, True),

        # Structural patterns
        (r"\*\.[a-zA-Z0-9_*.-]+|\*\*/*", 1.2, True),
        (r"[a-zA-Z0-9_-]+/[a-zA-Z0-9_-]+", 0.8, False),
    ]

    # First-pass scan of positive patterns to compute positive score and determine gating exemption
    pos_score = 0.0
    exempt_from_gates = False
    read_bulk_hit = False   # the 1.0 reading group (index -3: before the two structural patterns)
    scope_hit = False       # any of the scope groups (codebase-wide, multi-file, JA bulk, bulk intent, dir-wide)
    for i, (pattern, weight, is_exempt) in enumerate(positives):
        if re.search(pattern, text):
            pos_score += weight
            if is_exempt:
                exempt_from_gates = True
            if i == len(positives) - 3:
                read_bulk_hit = True
            if i in (0, 1, 2, 3, 6):
                scope_hit = True

    # Define sub-patterns used for both gating mechanisms and negative scoring
    pat_cli = r"\bgit (?:status|diff|log|branch|show|add|commit|push|pull|checkout|merge|rebase|clone|reset)\b|\breview diff\b|\bwhich branch\b|npm install|pip install|cargo build|npm run|go build|docker (?:ps|run|build)"
    
    pat_query_en = (
        r"\b(?:explain|clarify|how|why|what|where|help|is there|do we have|tell me|documentation for)\b"
    )
    pat_query_ja = (
        r"解説|説明|どうなっていますか|なぜ|どうやって|とは|教えて|確認|どうすれば|やり方|知りたい|教えろ|調べ方|"
        r"どこに|どこで|どういう|何ですか|何でしょう|ありますか|確認したい|確認してください|ドキュメント"
    )
    
    local_targets = r"(?:code|function|class|file|line|method|variable|endpoint|route|component|block|snippet)"
    local_targets_ja = r"(?:コード|関数|クラス|ファイル|メソッド|行|変数|モジュール|部分|ブロック)"
    pat_localized = (
        rf"\bthis {local_targets}\b|"
        rf"\bthe (?:following|above) {local_targets}\b|"
        r"\bhere\s*is\b|\bheres\b|"
        rf"(?:この|その|あの|以下の|上記の?){local_targets_ja}"
    )
    pat_lines = r"\blines? \d+(?:-\d+)?\b|\b\d+行目?\b|行目で|\b(?:one|few|couple|several) lines?\b|1行|一行|数行"
    
    pat_typos = r"\btypos?\b|誤字|脱字|タイポ|スペル"
    pat_style = r"\bcolor\b|background-color|padding|margin|font-size|border-radius|line-height|\bcss\b|\bstylesheet\b|スタイルシート|レイアウト"
    pat_tweaks = r"\b(?:tweak|quick fix|minor|small|tiny|simple)s?\b|微調整|ちょっと|少し|だけ|のみ|単に|簡易|簡単|小規模|些細|軽微"
    pat_configs = r"\b(?:readme\.md|package\.json|requirements\.txt|cargo\.toml|\.gitignore|tsconfig\.json|go\.mod|pom\.xml|build\.gradle|composer\.json|\.env|eslint\.config\.\w+|webpack\.config\.\w+|vite\.config\.\w+|makefile|gemfile)\b"

    # Refine gating exemption if the prompt is primarily a query, localized, or minor edit
    is_query = bool(re.search(f"{pat_query_en}|{pat_query_ja}", text))
    is_localized = bool(re.search(f"{pat_localized}|{pat_lines}", text))
    is_minor = bool(re.search(f"{pat_typos}|{pat_style}|{pat_tweaks}|{pat_configs}", text))

    # A question is normally "just answer it" — unless it is a bulk READ with repository
    # scope, which is exactly what the delegation server is for.
    if is_query and pos_score < 5.0 and not (read_bulk_hit and scope_hit):
        exempt_from_gates = False
    if (is_localized or is_minor) and pos_score < 4.0:
        exempt_from_gates = False

    # Length-based bias adjustments
    bias = -0.5
    length = len(text) if is_japanese else len(text.split())

    # (threshold, penalty_default, penalty_exempt)
    short_thresholds = (
        [(8, -3.0, -1.0), (15, -1.8, -0.6), (30, -0.8, -0.3)]
        if is_japanese
        else [(4, -3.0, -1.0), (7, -1.8, -0.6), (12, -0.8, -0.3)]
    )
    for limit, pen_def, pen_ex in short_thresholds:
        if length < limit:
            bias += pen_ex if exempt_from_gates else pen_def
            break

    # (threshold, boost)
    long_thresholds = (
        [(600, 1.8), (400, 1.2), (200, 0.6), (100, 0.3)]
        if is_japanese
        else [(300, 1.8), (180, 1.2), (90, 0.6), (50, 0.3)]
    )
    for limit, boost in long_thresholds:
        if length > limit:
            bias += boost
            break

    # Gating adjustments
    if re.search(pat_cli, text):
        bias -= 3.5
    if not exempt_from_gates:
        if is_query:
            bias -= 3.0
        if is_localized:
            bias -= 3.0
        if is_minor:
            bias -= 2.5

    # Compute raw logit score
    z = bias + pos_score

    # Process negative patterns
    negatives = [
        (pat_query_en, -2.5),
        (pat_query_ja, -2.5),
        (pat_cli, -2.5),
        (pat_typos, -2.5),
        (pat_lines, -2.5),
        (pat_style, -1.8),
        (pat_tweaks, -1.2),
        (pat_configs, -1.5),
    ]

    for pattern, weight in negatives:
        if re.search(pattern, text):
            # Scale down negative impact if we have strong bulk/exempt scope
            factor = 1.0
            if exempt_from_gates:
                factor = 0.15 if pos_score >= 5.0 else 0.3
            actual_weight = weight * factor
            z += actual_weight

    # Logistic sigmoid function mapping output to [0.0, 1.0]
    score = 1.0 / (1.0 + math.exp(-z))

    return float(max(0.0, min(1.0, score)))

score = predict_delegation_score(prompt)
THRESHOLD = float(os.environ.get("CLAUDE_PLUGIN_OPTION_NUDGE_THRESHOLD", "0.6") or 0.6)
if os.environ.get("NUDGE_DEBUG_SCORE"):
    sys.stderr.write(f"score={score:.3f} threshold={THRESHOLD}\n")
sys.exit(0 if score >= THRESHOLD else 1)
PY
then
  HIT=1
fi

[ "$HIT" -eq 1 ] || exit 0

# Fixed nudge. Note the explicit "the judgment is yours" — this is material, not a mandate.
cat <<'JSON'
{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"[antigravity plugin] This prompt looks like BULK work (many files to read / migration / exhaustive inventory / a large change) — possibly above the delegation break-even. CONSIDER reading it through the delegation server first — digest_codebase for a question or orientation, delegate_task for an inventory or extraction (or the antigravity-delegate subagent) — so the bulk is read on the cheap side and only a file:line digest reaches you; then verify the references. THE JUDGMENT IS YOURS: if the task is actually small, self-contained, or judgement-heavy, do it yourself — delegating below the break-even is a measured net loss. Writing files stays with you; the server only reads. Decide silently; don't mention this notice."}}
JSON
exit 0
