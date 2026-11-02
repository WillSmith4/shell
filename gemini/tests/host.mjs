// Host check of the exact packaged upstream file tools; no model credentials.
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { checkFileTools } from './files.mjs';
import assert from 'node:assert/strict';
const root = await fs.mkdtemp(path.join(os.tmpdir(), 'gemini-files-'));
process.env.GEMINI_CLI_HOME = root;
try {
  const core = await import(pathToFileURL(path.resolve(process.argv[2] || 'Resources/gemini/bundle/chunk-RZ3ZVTZB.js')));
  await checkFileTools(core, root);
  console.log('PASS upstream Gemini write_file, read_file, and replace tools');
  // Check the iOS command preparation path without pretending to execute iOS.
  const platform = Object.getOwnPropertyDescriptor(process, 'platform');
  try {
    Object.defineProperty(process, 'platform', {...platform, value: 'ios'});
    const prepared = await core.ShellExecutionService.prepareExecution('printf ok', root, {sanitizationConfig:{}}, false, false);
    assert.match(prepared.program, /(?:^|[/\\])dash(?:\.exe)?$/);
    assert.deepEqual(prepared.args, ['-c', 'printf ok']);
    assert.equal(prepared.env.ASHELL_GEMINI_TOOLS, '1');
    console.log('PASS iOS Dash arguments and native transport selection');
  } finally {
    Object.defineProperty(process, 'platform', platform);
  }
} finally {
  await fs.rm(root, { recursive: true, force: true });
}
