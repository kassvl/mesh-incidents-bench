#!/usr/bin/env bash
set -euo pipefail
kubectl -n demo delete authorizationpolicy payments-block-loadgen --ignore-not-found
