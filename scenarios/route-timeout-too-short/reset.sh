#!/usr/bin/env bash
set -euo pipefail
# Restore the payments VirtualService to its original routes with no timeout.
kubectl -n demo patch virtualservice payments --type=merge -p \
  '{"spec":{"http":[{"route":[{"destination":{"host":"payments","subset":"v1"},"weight":80},{"destination":{"host":"payments","subset":"v2"},"weight":20}]}]}}'
