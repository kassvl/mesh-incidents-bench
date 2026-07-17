#!/usr/bin/env bash
# Injects harmless noise, no fault. See ground-truth.md for why.
set -euo pipefail

kubectl -n demo create configmap legacy-feature-flags \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: payments-legacy
  namespace: demo
spec:
  selector:
    app: payments-legacy-retired
  ports:
    - port: 8080
      targetPort: 8080
EOF

# A one-off pod that completes successfully: benign events, Completed state.
kubectl -n demo delete pod one-off-migration --ignore-not-found >/dev/null 2>&1
kubectl -n demo run one-off-migration --image=busybox:1.36 --restart=Never \
  --labels=purpose=bench-noise -- /bin/sh -c 'echo migration done'
kubectl -n demo wait pod/one-off-migration \
  --for=jsonpath='{.status.phase}'=Succeeded --timeout=120s
