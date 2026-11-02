// Host check of the exact packaged upstream file tools; no model credentials.
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { checkFileTools } from './files.mjs';
const root = await fs.mkdtemp(path.join(os.tmpdir(), 'gemini-files-'));
process.env.GEMINI_CLI_HOME = root;
try {
  const core = await import(pathToFileURL(path.resolve(process.argv[2] || 'Resources/gemini/bundle/chunk-RZ3ZVTZB.js')));
  await checkFileTools(core, root);
  console.log('PASS upstream Gemini write_file, read_file, and replace tools');
} finally {
  await fs.rm(root, { recursive: true, force: true });
}
