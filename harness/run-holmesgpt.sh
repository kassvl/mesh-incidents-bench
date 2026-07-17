#!/usr/bin/env bash
# HolmesGPT adapter. Model comes from ~/.holmes/config.yaml (disclosed in
# results); the key from ~/.holmes.env, which is never committed. The prompt
# is identical for every scenario so no tool gets a hint.
set -euo pipefail
# shellcheck disable=SC1090
source ~/.holmes.env
export PATH="$HOME/.local/bin:$PATH"
# Route through the serializing proxy when it is up, so rate-limited keys
# (Mistral experiment tier: 4 requests/minute) pace out instead of 429ing.
if curl -sf -o /dev/null --max-time 2 http://127.0.0.1:8787/v1/models -H "Authorization: Bearer $MISTRAL_API_KEY" 2>/dev/null; then
  export MISTRAL_API_BASE=http://127.0.0.1:8787/v1
fi
exec holmes ask \
  "Users report problems with the payments service in the demo namespace of this cluster. Investigate what is wrong, find the root cause, and recommend a specific fix. Prometheus is available to you." \
  --max-steps 15
