#!/usr/bin/env bash
# HolmesGPT adapter. Model comes from ~/.holmes/config.yaml (disclosed in
# results); the key from ~/.holmes.env, which is never committed. The prompt
# is identical for every scenario so no tool gets a hint.
set -euo pipefail
# shellcheck disable=SC1090
source ~/.holmes.env
export PATH="$HOME/.local/bin:$PATH"
exec holmes ask \
  "Users report problems with the payments service in the demo namespace of this cluster. Investigate what is wrong, find the root cause, and recommend a specific fix. Prometheus is available to you." \
  --max-steps 15
