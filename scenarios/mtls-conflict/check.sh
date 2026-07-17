#!/usr/bin/env bash
# Exits 0 while the plaintext client is being rejected by the mesh.
set -euo pipefail
if kubectl -n default exec plain-client -- curl -s -m 3 -o /dev/null http://payments.demo:9090/ 2>/dev/null; then
  exit 1   # the request went through, incident not live
fi
exit 0
