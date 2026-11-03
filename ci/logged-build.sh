#!/usr/bin/env bash
# Retain complete compiler diagnostics and expose bounded live progress in CI.
set -uo pipefail
log=${1:?Log file}
shift
mkdir -p "$(dirname "$log")"
started=$SECONDS
"$@" >"$log" 2>&1 &
builder=$!
(
  while kill -0 "$builder" 2>/dev/null; do
    sleep 60
    kill -0 "$builder" 2>/dev/null || break
    printf '\nBuild running for %s minutes; latest compiler output:\n' "$(((SECONDS-started)/60))"
    tail -n 3 "$log"
    # Also show whether expensive compiler/linker processes are consuming CPU.
    ps -axo pid,ppid,etime,pcpu,rss,comm | awk 'NR==1 || /rustc$|clang$|clang\+\+$|ld$|cc1$|cc1plus$/ {print}' | tail -n 10
  done
) &
monitor=$!
cleanup() {
  kill "$monitor" 2>/dev/null || true
  wait "$monitor" 2>/dev/null || true
}
trap 'kill "$builder" 2>/dev/null || true; cleanup; exit 130' INT TERM
wait "$builder"
status=$?
cleanup
if [[ $status != 0 ]]; then
  echo "Build failed with status $status: $log" >&2
  tail -n 60 "$log" >&2
fi
exit "$status"
