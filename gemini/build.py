#!/usr/bin/env python3
"""Bundle the checksum-pinned Gemini CLI with explicit a-Shell adaptations."""
import hashlib
from pathlib import Path
import shutil
import tarfile
import tempfile
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
VERSION = '0.66.0'
SHA256 = '269734d35287fbd8ed2982534258ecf4a95f184b6e06e6732e0d6850c28701d9'
CACHE = ROOT / '.build' / 'gemini'
OUTPUT = ROOT / 'Resources' / 'gemini'


def replace_once(text, before, after, path):
    if text.count(before) != 1:
        raise ValueError(f'{path}: expected exactly one patch location: {before[:70]}')
    return text.replace(before, after, 1)


def adapt(package):
    chunks = ['chunk-RZ3ZVTZB.js', 'chunk-HJ5KJXNZ.js', 'chunk-M44FJWED.js']
    for chunk in chunks:
        path = package / 'bundle' / chunk
        text = path.read_text(encoding='utf-8')
        text = replace_once(text, 'function getShellConfiguration() {', '''function getShellConfiguration() {
  // Dash is the embedded POSIX shell. Keep the upstream Bash parser/quoting.
  if (process.platform === "ios") {
    return { executable: "dash", argsPrefix: ["-c"], shell: "bash" };
  }''', path)
        text = replace_once(text, 'detached: !isWindows3 && !isBun,',
                            'detached: process.platform !== "ios" && !isWindows3 && !isBun,', path)
        text = replace_once(text, '      env: sandboxedCommand.env,', '''      // The adapter marker is local metadata, not a credential or shell setting.
      env: process.platform === "ios"
        ? { ...sandboxedCommand.env, ASHELL_GEMINI_TOOLS: "1" }
        : sandboxedCommand.env,''', path)
        # These IDs belong to the native adapter, never to OS process groups.
        text = replace_once(text, 'async function killProcessGroup(options) {', '''async function killProcessGroup(options) {
  if (process.platform === "ios") {
    const child = ShellExecutionService.activeChildProcesses.get(options.pid)?.process;
    if (child && !child.kill(options.signal || "SIGTERM")) {
      throw new Error("Could not cancel the a-Shell command tree.");
    }
    return;
  }''', path)
        text = replace_once(text, 'return process.kill(child.pid, 0);',
                            'return process.platform === "ios" ? !exited : process.kill(child.pid, 0);', path)
        # The SDK start method belongs to this class, not other transports.
        start = text.index('var StdioClientTransport = class {')
        end = text.index('\n};', start)
        section = text[start:end]
        section = replace_once(section, 'async start() {', '''async start() {
    if (process.platform === "ios") {
      throw new Error("Local stdio MCP servers are unsupported in a-Shell; use an HTTP MCP server.");
    }''', path)
        text = text[:start] + section + text[end:]
        path.write_text(text, encoding='utf-8', newline='\n')
    for name in ['gemini-22EOGL6O.js', 'gemini-B5V54E2S.js', 'gemini-EOCRFAPZ.js']:
        path = package / 'bundle' / name
        text = path.read_text(encoding='utf-8')
        text = replace_once(text, '  if (typeof sandbox === "string" && sandbox) {', '''  if (process.platform === "ios") {
    throw new FatalSandboxError("Desktop tool sandboxes are unavailable in a-Shell. The CLI runs inside the iOS app sandbox.");
  }
  if (typeof sandbox === "string" && sandbox) {''', path)
        path.write_text(text, encoding='utf-8', newline='\n')


def main():
    CACHE.mkdir(parents=True, exist_ok=True)
    archive = CACHE / f'gemini-cli-{VERSION}.tgz'
    if not archive.exists():
        urllib.request.urlretrieve(
            f'https://registry.npmjs.org/@google/gemini-cli/-/gemini-cli-{VERSION}.tgz', archive)
    if hashlib.sha256(archive.read_bytes()).hexdigest() != SHA256:
        raise ValueError(f'Gemini source checksum mismatch: {archive}')
    with tempfile.TemporaryDirectory(dir=CACHE) as temporary:
        stage = Path(temporary)
        with tarfile.open(archive) as source:
            source.extractall(stage, filter='data')
        package = stage / 'package'
        adapt(package)
        shutil.copy2(ROOT / 'gemini' / 'launcher.mjs', package / 'launcher.mjs')
        shutil.copytree(ROOT / 'gemini' / 'tests', package / 'tests')
        (package / 'ASHELL-BUILD.txt').write_text(
            f'Gemini CLI {VERSION}\nUpstream archive SHA-256: {SHA256}\n', encoding='utf-8')
        if OUTPUT.exists():
            if not (OUTPUT / 'ASHELL-BUILD.txt').exists():
                raise ValueError(f'Refusing to overwrite an unrecognized directory: {OUTPUT}')
            shutil.rmtree(OUTPUT)
        shutil.copytree(package, OUTPUT)
    print(f'Bundled Gemini CLI {VERSION} in {OUTPUT}')


if __name__ == '__main__':
    main()
