// Native Simulator harness: tests real Gemini shell service without app-only WASM/Python.
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
const root = await fs.mkdtemp(path.join(os.tmpdir(), 'gemini-shell-'));
process.env.GEMINI_CLI_HOME = root;
const {ShellExecutionService} = await import(pathToFileURL(path.join(process.env.APPDIR,'gemini/bundle/chunk-RZ3ZVTZB.js')));
async function shell(cmd, signal = new AbortController().signal) {
  return (await ShellExecutionService.execute(cmd, root, () => {}, signal, false, {})).result;
}
try {
  const first = await shell('printf "hello\\n"; exit 7');
  assert.equal(first.exitCode, 7, JSON.stringify(first));
  assert.equal(first.output, 'hello');
  const parallel = await Promise.all([shell('printf A'),shell('printf B')]);
  assert.deepEqual(parallel.map(x=>[x.exitCode,x.output]),[[0,'A'],[0,'B']]);
  const controller = new AbortController();
  const timer = setTimeout(()=>controller.abort(),500);
  const interrupted = await shell('sleep 20',controller.signal);
  clearTimeout(timer);
  assert.equal(interrupted.exitCode,130,JSON.stringify(interrupted));
  const next = await shell('printf recovered');
  assert.equal(next.output,'recovered');
  assert.equal(next.exitCode,0);
  console.log('PASS Gemini native shell, status, queued calls, cancellation, recovery');
} finally {await fs.rm(root,{recursive:true,force:true});}
