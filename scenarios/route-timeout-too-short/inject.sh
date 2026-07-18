#!/usr/bin/env bash
set -euo pipefail
# Add a 10ms route timeout to the payments VirtualService, below the ~20ms
# backend latency, so requests are cut off as HTTP 504 with the UT flag
# while payments itself is healthy. Preserves the existing 80/20 v1/v2 split.
kubectl -n demo patch virtualservice payments --type=merge -p \
  '{"spec":{"http":[{"timeout":"0.01s","route":[{"destination":{"host":"payments","subset":"v1"},"weight":80},{"destination":{"host":"payments","subset":"v2"},"weight":20}]}]}}'
