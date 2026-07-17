#!/usr/bin/env bash
set -euo pipefail
kubectl -n demo delete configmap legacy-feature-flags --ignore-not-found
kubectl -n demo delete service payments-legacy --ignore-not-found
kubectl -n demo delete pod one-off-migration --ignore-not-found
