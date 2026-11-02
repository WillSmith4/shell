// Run in the built a-Shell app: node "$APPDIR/gemini/tests/capabilities.mjs"
// Exercises the shipped upstream shell service with real ios_system commands.
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { checkFileTools } from './files.mjs';

assert.equal(process.platform, 'ios', 'Run this acceptance test inside a-Shell');
const bundle = path.join(process.env.APPDIR, 'gemini', 'bundle');
const root = await fs.mkdtemp(path.join(os.tmpdir(), 'gemini-acceptance-'));
process.env.GEMINI_CLI_HOME = root;
const core = await import(pathToFileURL(path.join(bundle, 'chunk-RZ3ZVTZB.js')));
const { ShellExecutionService } = core;
const controller = new AbortController();
const quote = value => "'" + value.replaceAll("'", "'\\''") + "'";
async function shell(command, expected = 0, signal = controller.signal) {
  const execution = await ShellExecutionService.execute(command, root, () => {}, signal, false, {});
  const result = await execution.result;
  assert.equal(result.exitCode, expected, JSON.stringify(result));
  assert.equal(result.error, null, JSON.stringify(result));
  return result.output;
}

try {
  const file = await checkFileTools(core, root);
  assert.equal((await shell(`python3 ${quote(file)}`)).trim(), 'after');
  console.log('PASS project read, edit, and python3 execution');

  assert.equal((await shell('printf "STATUS_OK\\n"; exit 7', 7)).trim(), 'STATUS_OK');
  const missing = await shell('ls ./gemini-missing-file', 1);
  assert.match(missing, /gemini-missing-file/);
  console.log('PASS stdout, stderr, and exit status');

  // Same WASM command and pipeline as the native Codex acceptance fixture.
  assert.match(await shell('mktemp -d ./gemini-wasm-XXXXXX | cat'), /gemini-wasm-/);
  console.log('PASS a-Shell WASM pipeline');

  const [a, b] = await Promise.all([shell('printf A'), shell('printf B')]);
  assert.equal(a, 'A'); assert.equal(b, 'B');
  console.log('PASS queued command isolation');

  const abort = new AbortController();
  const running = ShellExecutionService.execute('printf READY; sleep 30', root, event => {
    if (event.type === 'data' && event.chunk.includes('READY')) abort.abort();
  }, abort.signal, false, {});
  const interrupted = await (await running).result;
  assert.equal(interrupted.aborted, true);
  assert.equal(interrupted.exitCode, 130);
  assert.equal(await shell('printf RECOVERED'), 'RECOVERED');
  console.log('PASS cancellation and next command');

  const wasm = new Uint8Array([0,97,115,109,1,0,0,0,1,5,1,96,0,1,127,3,2,1,0,7,10,1,6,97,110,115,119,101,114,0,0,10,6,1,4,0,65,42,11]);
  const { instance } = await WebAssembly.instantiate(wasm);
  assert.equal(instance.exports.answer(), 42);
  const response = await fetch('https://example.com', { signal: AbortSignal.timeout(30000) });
  assert.equal(response.status, 200);
  assert.match(await response.text(), /Example Domain/);
  console.log('PASS WebAssembly execution and verified HTTPS');
  console.log('PASS all Gemini capabilities');
} finally {
  await fs.rm(root, { recursive: true, force: true });
}
