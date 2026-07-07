const fs = require('fs');

const nudge = (process.env.CLAUDE_PLUGIN_OPTION_DELEGATION_NUDGE || 'on').toLowerCase().trim();
if (['off', 'false', '0', 'no', 'disabled'].includes(nudge)) {
  process.exit(0);
}

let input = '';
try {
  input = fs.readFileSync(0, 'utf8');
} catch (e) {
  process.exit(0);
}

if (!input) {
  process.exit(0);
}

let prompt = '';
try {
  const data = JSON.parse(input);
  prompt = data.prompt || '';
} catch (e) {
  process.exit(0);
}

if (!prompt) {
  process.exit(0);
}

if (/antigravity|agy-delegate|agy-job/i.test(prompt)) {
  process.exit(0);
}

const keywords = [
  "all files", "every file", "across the codebase", "entire codebase", "whole repo",
  "migrate", "migration", "generate tests", "test coverage", "exhaustive test",
  "scaffold", "boilerplate", "deep research", "web search",
  "一括", "全ファイル", "すべてのファイル", "網羅", "移行", "大量", "横断", "リポジトリ全体"
];

const promptLower = prompt.toLowerCase();
const hit = keywords.some(kw => promptLower.includes(kw.toLowerCase()));

if (hit) {
  const output = {
    hookSpecificOutput: {
      hookEventName: "UserPromptSubmit",
      additionalContext: "[antigravity plugin] This prompt looks like BULK work (mass edits / migration / exhaustive tests / fan-out search) — possibly above the delegation break-even. CONSIDER routing the bulk part to the antigravity-delegate subagent (or agy-delegate --digest) so it runs on the cheap executor, then verify its digest. THE JUDGMENT IS YOURS: if the task is actually small, self-contained, or judgement-heavy, do it yourself — delegating below the break-even is a measured net loss. Decide silently; don't mention this notice."
    }
  };
  console.log(JSON.stringify(output));
}
process.exit(0);
