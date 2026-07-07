const { execSync } = require('child_process');

let hasAgy = false;
try {
  const checkCmd = process.platform === 'win32' ? 'where agy' : 'which agy';
  execSync(checkCmd, { stdio: 'ignore' });
  hasAgy = true;
} catch (e) {
  hasAgy = false;
}

if (!hasAgy) {
  console.error("[antigravity] agy not on PATH — install the Antigravity CLI to enable delegation:");
  console.error("[antigravity]   https://antigravity.google/docs/cli-using");
  process.exit(0);
}

try {
  execSync('agy --version', { shell: true, stdio: 'ignore', timeout: 5000 });
} catch (e) {
  console.error("[antigravity] agy is on PATH but '--version' failed — it may need authentication (run `agy` once).");
}
process.exit(0);
