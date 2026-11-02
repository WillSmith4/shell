import assert from 'node:assert/strict';
import fs from 'node:fs/promises';

// Test upstream tools themselves; only unexpected external model requests fail.
export async function checkFileTools(core, root) {
  const config = new core.Config({ sessionId: 'ashell-test', targetDir: root, cwd: root, model: 'test', debugMode: false });
  await config.storage.initialize();
  config.getBaseLlmClient = () => ({ generateContent() {
    throw new Error('Unexpected model call in deterministic file test');
  } });
  const bus = config.getMessageBus();
  const options = { abortSignal: AbortSignal.timeout(5000) };
  const file = root + '/script.py';
  const write = await new core.WriteFileTool(config, bus)
    .build({ file_path: file, content: 'print("before")\n' }).execute(options);
  assert.equal(write.error, undefined, JSON.stringify(write));
  const read = await new core.ReadFileTool(config, bus)
    .build({ file_path: file }).execute(options);
  assert.equal(read.error, undefined, JSON.stringify(read));
  assert.match(read.llmContent, /print\("before"\)/);
  const edit = await new core.EditTool(config, bus)
    .build({ instruction: 'Replace before with after', file_path: file, old_string: 'before', new_string: 'after' }).execute(options);
  assert.equal(edit.error, undefined, JSON.stringify(edit));
  assert.equal((await fs.readFile(file, 'utf8')).replaceAll('\r\n', '\n'), 'print("after")\n');
  return file;
}
