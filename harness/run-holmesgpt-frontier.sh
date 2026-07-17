#!/usr/bin/env bash
# HolmesGPT adapter, frontier-model edition. Same hint-free prompt and the
# same --max-steps 15 as the mistral adapter, so runs stay comparable; only
# the model changes. Reads the key from ~/.holmes.env, which is never
# committed: ANTHROPIC_API_KEY selects claude-opus-4-8, otherwise
# OPENAI_API_KEY selects gpt-4o. Paid-tier keys need no throttle proxy.
set -euo pipefail
# shellcheck disable=SC1090
source ~/.holmes.env
export PATH="$HOME/.local/bin:$PATH"

if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
  MODEL="anthropic/claude-opus-4-8"
elif [ -n "${OPENAI_API_KEY:-}" ]; then
  MODEL="openai/gpt-4o"
else
  echo "run-holmesgpt-frontier.sh: no ANTHROPIC_API_KEY or OPENAI_API_KEY in ~/.holmes.env" >&2
  exit 1
fi

exec holmes ask \
  "Users report problems with the payments service in the demo namespace of this cluster. Investigate what is wrong, find the root cause, and recommend a specific fix. Prometheus is available to you." \
  --max-steps 15 --model "$MODEL"