const fs = require('fs');

let input = '';
try {
  input = fs.readFileSync(0, 'utf8');
} catch (e) {
  process.exit(2);
}

let cmd = input;
try {
  const data = JSON.parse(input);
  cmd = data.tool_input?.command || '';
} catch (e) {
  // If parsing fails, fall back to matching on raw input string
}

if (/agy-delegate|agy-job/.test(cmd)) {
  process.exit(0);
}

console.error("[antigravity-delegate] blocked: this subagent may only run agy-delegate / agy-job via Bash. Delegate file work to agy; verification is the caller's job.");
process.exit(2);
