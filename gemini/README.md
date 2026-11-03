# Gemini CLI in a-Shell

The full app bundles Gemini CLI 0.66.0, pinned by archive checksum. Run
`python3 gemini/build.py` before building the app. `gemini` launches it using the
embedded Node command, without npm installation or a process relaunch.

The port targets the same practical command capabilities as native Codex:
upstream file reading and editing, HTTPS, and embedded Dash tools including
`python3` and a-Shell WASM commands. Gemini retains its upstream approval and
workspace checks. Its Node child adapter compiles the tool-runner section of
`codex/command.m`, with identical fresh sessions, copied environments, owned
stream barriers, serialized working directories, cancellation and cleanup.
The bridge applies only to Gemini spawns; other Node invocations retain their
existing child-process behavior.

V8's DrumBrake interpreter runs Gemini's WebAssembly dependencies (including
Undici's llhttp parser) without JIT. Merely using the app's `wasm` command does
not provide the Node `WebAssembly` API. Both compilation and runtime execution
must be verified before claiming this port is supported on a device.

The launcher selects manual authentication (`NO_BROWSER=true`). Use Gemini's
normal API-key or manual Google authentication flow. Credentials are supplied
by the user. No browser command or login credential is embedded.
An explicit `GEMINI_CLI_HOME` is respected. An existing `$HOME/.gemini` is kept;
otherwise settings and sessions use `$GROUP/Library/gemini/.gemini` (falling back
to `$HOME/Library/gemini/.gemini` when no app-group path is available).

Local stdio MCP servers and desktop tool sandboxes are rejected. HTTP MCP keeps
its upstream transport. Native Node addons, arbitrary Linux executables, and
installation of arbitrary native Python libraries are unsupported. Interactive
tool PTYs are unavailable, as in native Codex. The Gemini terminal itself uses
a-Shell's input, raw-mode and window-size callbacks.

## Checks

`node gemini/tests/host.mjs` checks the packaged upstream `write_file`,
`read_file`, and replacement tools using disposable files. It supplies no model
credentials and fails if a model correction is unexpectedly requested.

In a disposable directory of the full app, after its normal prompt is ready:

```sh
gemini --version
gemini --help
node "$APPDIR/gemini/tests/capabilities.mjs"
```

The capability suite uses the shipped Gemini shell service and real native
commands. It checks file edits followed by Python execution, exit statuses,
stderr, WASM pipelines, queued commands, interruption/recovery, WebAssembly
execution and verified HTTPS. It requires `mktemp`, as does Codex's existing
tool fixture. No Python or WASM test is skipped when that dependency is missing.

Interactive acceptance additionally requires typing, paste, resize, Ctrl-C,
exit and same-process reentry on iPadOS 17.5.1. Host checks do not establish iOS
runtime compatibility.
