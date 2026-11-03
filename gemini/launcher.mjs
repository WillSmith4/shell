// Apply invocation-local settings before importing the upstream entry point.
// Node environments in a-Shell have independent process.env maps.
if (process.platform === 'ios') {
  if (typeof WebAssembly !== 'object') {
    throw new Error('Gemini requires the a-Shell Node build with the WebAssembly interpreter enabled.');
  }
  process.env.GEMINI_CLI_NO_RELAUNCH = 'true';
  process.env.GEMINI_PTY_INFO = 'child_process';
  process.env.ASHELL_GEMINI_TOOLS = '1';
  process.env.NO_BROWSER = 'true';
  if (!process.env.GEMINI_CLI_HOME) {
    const fs = await import('node:fs');
    const path = await import('node:path');
    const home = process.env.HOME;
    if (home && fs.existsSync(path.join(home, '.gemini'))) {
      process.env.GEMINI_CLI_HOME = home;
    } else {
      const base = process.env.GROUP || home;
      if (!base) throw new Error('Cannot locate a writable a-Shell Gemini home.');
      const state = path.join(base, 'Library', 'gemini');
      fs.mkdirSync(state, {recursive:true, mode:0o700});
      process.env.GEMINI_CLI_HOME = state;
    }
  }
}
await import('./bundle/gemini.js');
