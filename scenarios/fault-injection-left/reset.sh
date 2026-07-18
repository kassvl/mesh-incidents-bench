#!/usr/bin/env bash
set -euo pipefail
kubectl -n demo patch virtualservice payments --type=json -p '[{"op":"remove","path":"/spec/http/0/fault"}]' 2>/dev/null || true
