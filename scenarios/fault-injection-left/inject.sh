#!/usr/bin/env bash
set -euo pipefail
# A leftover fault-injection VirtualService: abort 50% of payments requests
# with 503. Endpoints stay healthy; the failures are synthetic (FI flag).
kubectl -n demo patch virtualservice payments --type=merge -p \
  '{"spec":{"http":[{"fault":{"abort":{"percentage":{"value":50},"httpStatus":503}},"route":[{"destination":{"host":"payments","subset":"v1"},"weight":80},{"destination":{"host":"payments","subset":"v2"},"weight":20}]}]}}'
