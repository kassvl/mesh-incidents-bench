#!/usr/bin/env bash
# Run one scenario against one tool:
#   ./harness/run.sh scenarios/<id> <tool-seconds> -- <tool command...>
# Injects the fault, waits until check.sh confirms the incident is live,
# runs the tool while the incident is happening, captures its output, and
# resets the testbed.
set -euo pipefail

SCENARIO_DIR="$1"; shift
TOOL_SECONDS="$1"; shift
[ "$1" = "--" ] && shift

ID="$(basename "$SCENARIO_DIR")"
TOOL_NAME="$(basename "$1")"
OUT_DIR="$(dirname "$0")/../results/raw"
mkdir -p "$OUT_DIR"
OUT="$OUT_DIR/${ID}-${TOOL_NAME}-$(date +%Y%m%d-%H%M%S).txt"

cleanup() { "$SCENARIO_DIR/reset.sh" || true; }
trap cleanup EXIT

# Residual telemetry from a previous scenario decays over the PromQL rate
# windows (2m in the scenarios here) and can make a tool fire on the wrong
# incident. Learned the hard way: a stale UO tail from pool-overflow leaked
# into the next run. Let signals settle before injecting.
QUIESCE="${QUIESCE:-150}"
echo "== quiesce: waiting ${QUIESCE}s for residual signals to clear"
sleep "$QUIESCE"

echo "== inject: $ID"
"$SCENARIO_DIR/inject.sh"

echo "== waiting for the incident to be observable"
for i in $(seq 1 60); do
  if "$SCENARIO_DIR/check.sh" >/dev/null 2>&1; then
    echo "== incident live after ~$((i * 10))s"
    break
  fi
  [ "$i" = 60 ] && { echo "incident never became observable"; exit 1; }
  sleep 10
done

echo "== running tool for ${TOOL_SECONDS}s: $*"
{
  echo "# scenario: $ID"
  echo "# tool: $*"
  echo "# date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo
} > "$OUT"
# One-shot tools (an ask-style CLI) exit on their own; watcher-style tools
# (meshmedic watch) run until the window closes. Support both: wait for the
# tool, with a watchdog that caps the window.
"$@" >> "$OUT" 2>&1 &
TOOL_PID=$!
# SIGTERM first, SIGKILL twenty seconds later: one HolmesGPT run ignored
# the TERM and kept the harness waiting for seven hours.
( sleep "$TOOL_SECONDS"; kill "$TOOL_PID" 2>/dev/null; sleep 20; kill -9 "$TOOL_PID" 2>/dev/null ) &
WATCHDOG=$!
wait "$TOOL_PID" 2>/dev/null || true
kill "$WATCHDOG" 2>/dev/null || true
cat "$OUT"

echo "== output saved to $OUT"
