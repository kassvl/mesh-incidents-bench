# mtls-conflict: ground truth

**Fault**: the `demo` namespace is switched to STRICT mTLS while a client
outside the mesh (no sidecar, not enrolled in ambient) keeps calling
`payments` in plaintext. The client's requests fail from that moment on.

**Root cause**: mTLS policy conflict: STRICT PeerAuthentication versus a
plaintext, out-of-mesh caller.

**Correct remediation**: enroll the client into the mesh (ambient label or
sidecar), or apply a scoped PERMISSIVE PeerAuthentication on the affected
workload as an explicit, temporary de-escalation while the client migrates.

**Known hard case**: in ambient mode the rejection happens at L4 (ztunnel),
so it may never appear in L7 request metrics. Metric-only tools are expected
to struggle here; that is the point of the scenario. Signals exist in ztunnel
logs and in the client's own error rate.

## Scoring rubric

| points | detection | diagnosis | remediation |
| --- | --- | --- | --- |
| 0 | nothing flagged | no cause named | none or harmful |
| 1 | client failures flagged | TLS suspected, policy missed | generic (restart, network debug) |
| 2 | rejected plaintext flagged | STRICT vs plaintext client named | enroll client or scoped PERMISSIVE |
