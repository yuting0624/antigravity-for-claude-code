const fs = require('fs');
const path = require('path');

const codingPolicy = (process.env.CLAUDE_PLUGIN_OPTION_CODING_POLICY || 'on').toLowerCase().trim();
if (['off', 'false', '0', 'no', 'disabled'].includes(codingPolicy)) {
  process.exit(0);
}

try {
  const policyPath = path.join(__dirname, 'policy-context.json');
  const policy = fs.readFileSync(policyPath, 'utf8');
  process.stdout.write(policy);
} catch (e) {
  console.error("Error reading policy-context.json:", e);
  process.exit(1);
}
process.exit(0);
