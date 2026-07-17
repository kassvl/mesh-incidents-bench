#!/usr/bin/env bash
set -euo pipefail
kubectl -n demo delete peerauthentication demo-strict --ignore-not-found
kubectl -n default delete pod plain-client --ignore-not-found --grace-period=1
