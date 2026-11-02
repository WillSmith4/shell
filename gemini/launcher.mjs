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
}
await import('./bundle/gemini.js');
