// Gemini probes for optional desktop programs during interactive startup.
const assert = require('node:assert/strict');
const { spawn } = require('node:child_process');
const child = spawn('ashell-missing-startup-probe', []);
const events = [];
for (const stream of [child.stdout, child.stderr]) {
  stream.resume();
  stream.on('error', error => assert.fail(`Unexpected pipe error: ${error}`));
}
child.on('error', error => { assert.equal(error.code, 'ENOENT'); events.push('error'); });
child.on('close', () => { events.push('close'); });
process.on('beforeExit', () => {
  assert.deepEqual(events, ['error', 'close']);
  console.log('PASS unsuccessful startup probe reports ENOENT and closes its streams');
});
