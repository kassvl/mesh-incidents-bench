# Security / mTLS / authorization failure candidates

Nine candidates below cover the AuthorizationPolicy, RequestAuthentication/JWT,
PeerAuthentication, and certificate territory that the two existing mTLS
catalog entries (`mtls-policy-conflict.yaml`, sidecar-mode STRICT-vs-plaintext,
and `mtls-policy-conflict-ambient.yaml`, the ztunnel L4 DENY variant) do not
cover: explicit RBAC decisions (403s), JWT/issuer misconfiguration (401s),
port-scoped PeerAuthentication overrides, external-authorizer availability
coupling, and certificate/trust-domain root-cause variants that *reuse* the
existing 503 UF/URX or DENY signature but need different triage evidence to
attribute correctly. One candidate (#5) turned out, on inspection, to already
be fully covered by `mtls-policy-conflict.yaml` - it is kept in for the
taxonomy's L7-vs-L4 contrast but flagged as a duplicate, not a new class.
Every candidate is grounded in at least one real istio/istio (or envoyproxy)
GitHub issue or an istio.io doc page; where the payments testbed can't
reproduce a mechanism (multi-cluster, control-plane cert rotation), that's
stated plainly rather than guessed at.

## authz-deny-rule-too-broad

- **Mechanism**: A `DENY` `AuthorizationPolicy` meant to block a narrow set of
  callers/paths omits scoping (no `to.operation.ports`, or a `from`-only rule
  with no `to`), and Envoy's RBAC filter treats missing attributes in a DENY
  rule as a wildcard match - so the policy denies far more traffic than
  intended, including legitimate callers on the same workload/port.
- **Telemetry signature**: `istio_requests_total{response_code="403"}` rises
  for callers that previously succeeded. `response_flags` stays `"-"` for
  both AuthorizationPolicy denials and application-level 403s (confirmed gap,
  see sources) - response_code alone doesn't attribute the cause, only the
  policy-apply-time correlation does.
- **Signal draft (PromQL)**: `sum by (source_workload) (rate(istio_requests_total{reporter="destination", destination_service_name="payments", destination_service_namespace="demo", response_code="403"}[2m])) > 0`
- **Inject sketch**: `kubectl apply` an `AuthorizationPolicy` in `demo`
  selecting `app: payments`, `action: DENY`, with a rule that has only a
  `from.source.notPrincipals` clause and no `to` - this denies every
  operation/port for anything not in the exception list, catching `loadgen`.
- **Triage signatures**: `kubectl get authorizationpolicy -n demo -o yaml`
  showing a DENY rule with no `to.operation` scoping; the policy's
  `metadata.creationTimestamp` lining up with the 403 onset; RBAC debug log
  (`istioctl proxy-config log <pod> --level rbac:debug`) naming the matched
  DENY policy.
- **Detectable deterministically?**: partial - the 403-rate step change is a
  clean deterministic signal and time-correlates with the object change, but
  distinguishing "AuthorizationPolicy 403" from an app-level 403 needs the
  object diff since `response_flags` doesn't discriminate between them.
- **Overlaps existing catalog?**: new - an explicit RBAC decision, not a
  handshake/identity failure like either mTLS entry.
- **Sources**: https://github.com/istio/istio/issues/24845 ,
  https://github.com/istio/istio/issues/29567 ,
  https://github.com/istio/istio/issues/44348 ,
  https://istio.io/latest/docs/reference/config/security/authorization-policy/

## authz-scoped-allow-default-deny-gap

- **Mechanism**: Istio authorization is deny-by-default the moment *any*
  `AuthorizationPolicy` with `action: ALLOW` selects a workload. Adding one
  narrowly-scoped ALLOW (e.g. "let the canary service account in") silently
  flips the workload from allow-all to deny-all-except-this-rule, breaking
  every other legitimate caller that wasn't enumerated - a well-documented
  Istio authoring gotcha, distinct from a DENY rule being too broad (#1: here
  the admin's rule is narrow and correct, the *side effect* is broad).
- **Telemetry signature**: `istio_requests_total{response_code="403"}` for
  every `source_workload` except the one named in the new ALLOW rule,
  appearing as a step function at the policy's apply time rather than a
  gradual rise.
- **Signal draft (PromQL)**: `sum by (source_workload) (rate(istio_requests_total{destination_service_name="payments", destination_service_namespace="demo", response_code="403"}[2m]))` - compare against the ALLOW policy's named principal to see who's missing.
- **Inject sketch**: `kubectl apply` an `AuthorizationPolicy` in `demo`
  selecting `app: payments`, `action: ALLOW`, with a single rule
  `from.source.principals: ["cluster.local/ns/demo/sa/payments-v2"]` - this
  immediately blocks `loadgen` and any v1-originated calls that aren't in the
  list.
- **Triage signatures**: `kubectl get authorizationpolicy -n demo -o yaml`
  showing exactly one ALLOW rule with a narrow principal list and no other
  policies present; envoy/ztunnel access log `RBAC: access denied` with no
  matched policy for the blocked caller.
- **Detectable deterministically?**: partial - the step-change in 403 rate at
  apply time is a strong signal, but attributing *why* (first-ALLOW-implies-
  default-deny) requires the object evidence, not the metric alone.
- **Overlaps existing catalog?**: new.
- **Sources**: https://istio.io/latest/docs/ops/common-problems/security-issues/ ,
  https://github.com/istio/istio/issues/36119 ,
  https://istio.io/latest/docs/tasks/security/authorization/authz-http/

## authz-selector-typo-silent-mismatch

- **Mechanism**: An `AuthorizationPolicy` selector (namespace string, service
  account name, principal SPIFFE URI) has a typo, so it never matches real
  traffic. If the intent was ALLOW, this collapses to #2's default-deny gap
  but the root cause is a fat-fingered string, not policy design - and
  confusingly, the "excepted" caller fails too, since its principal never
  actually matched. If the intent was DENY, the policy silently does
  nothing: a security hole with zero incident telemetry, since the thing it
  should have blocked keeps succeeding.
- **Telemetry signature**: ALLOW-typo case: identical to #2
  (`response_code="403"` for callers who should be allowed, including the
  supposedly-excepted one). DENY-typo case: no mesh signal - the absence of
  a 403 that should exist; only visible by diffing the policy's selector
  strings against real `source_principal`/`source_workload_namespace` label
  values in `istio_requests_total`.
- **Signal draft (PromQL)**: `sum by (source_principal) (rate(istio_requests_total{destination_service_name="payments", destination_service_namespace="demo"}[5m]))` - a principal absent from the policy's `principals` list but present with `response_code="200"` is the tell for a silently-ineffective DENY.
- **Inject sketch**: `kubectl apply` an `AuthorizationPolicy` with
  `source.principals: ["cluster.local/ns/dmeo/sa/payments-v2"]` (namespace
  typo `dmeo`) intended as an ALLOW-only-v2 rule - every caller, including
  the real v2 workload, gets denied by the resulting default-deny, and the
  intended exception never fires.
- **Triage signatures**: `kubectl get authorizationpolicy -o yaml` diffed
  against `kubectl get sa,ns` for the real object names; `istioctl
  proxy-config log <pod> --level rbac:debug` showing zero matches for the
  intended principal string.
- **Detectable deterministically?**: partial for the ALLOW-typo variant
  (looks identical to #2 in metrics, needs the object diff to find the
  actual typo); no for the DENY-typo variant (nothing breaks - there is no
  incident signal at all, only a config-review catch).
- **Overlaps existing catalog?**: new.
- **Sources**: https://github.com/istio/istio/issues/42332 ,
  https://github.com/istio/istio/issues/46591 ,
  https://github.com/istio/istio/issues/55802 ,
  https://github.com/istio/istio/issues/51901

## jwt-requestauth-issuer-jwksuri-misconfig

- **Mechanism**: A `RequestAuthentication` names an `issuer` or `jwksUri`
  that's wrong, unreachable, or requires a CA istiod doesn't trust. Every
  request bearing a JWT meant for that issuer fails verification and Envoy's
  `jwt_authn` filter returns 401 before the request reaches authorization or
  business logic - independent of any AuthorizationPolicy content.
- **Telemetry signature**: `istio_requests_total{response_code="401"}` rises
  for the affected `destination_service`/route right after the
  `RequestAuthentication` is applied or changed. Like the RBAC case, the
  local-reply `response_flags` value for a JWT-filter rejection is not a
  distinct documented flag (no dedicated flag found in the sources below)  - 
  the 401 rate plus timing correlation with the object's `resourceVersion`
  is the practical signal.
- **Signal draft (PromQL)**: `sum(rate(istio_requests_total{destination_service_name="payments", destination_service_namespace="demo", response_code="401"}[2m])) > 0`
- **Inject sketch**: `kubectl apply` a `RequestAuthentication` in `demo`
  selecting `app: payments` with `jwtRules: [{issuer:
  "https://wrong-issuer.example.com", jwksUri:
  "https://wrong-issuer.example.com/.well-known/jwks.json"}]`, paired with an
  `AuthorizationPolicy` requiring `requestPrincipals: ["*"]` - `loadgen`'s
  unauthenticated requests start failing with 401.
- **Triage signatures**: `kubectl get requestauthentication -n demo -o yaml`;
  istiod logs grep `Failed to fetch public key` /
  `IstiodFailedToFetchJwksUri`; envoy access log text `Jwt issuer is not
  configured` / `Jwt is expired`.
- **Detectable deterministically?**: partial - the 401 step-change is clean
  and the `RequestAuthentication` object confirms the issuer/jwksUri fields
  quickly, but distinguishing "wrong issuer" vs "jwksUri unreachable" vs
  "client sent no token" needs the istiod/envoy log text, not the metric
  alone.
- **Overlaps existing catalog?**: new.
- **Sources**: https://github.com/istio/istio/issues/40718 ,
  https://github.com/istio/istio/issues/39427 ,
  https://github.com/istio/istio/issues/53260 ,
  https://github.com/istio/istio/issues/26984 ,
  https://github.com/istio/istio/issues/54018 ,
  https://istio.io/latest/docs/tasks/security/authorization/authz-jwt/

## mtls-strict-sidecar-plaintext-caller

- **Mechanism**: Sidecar-mode STRICT `PeerAuthentication` rejects a plaintext
  (non-mesh) caller - in sidecar mode this surfaces as a request-layer TLS
  handshake failure rather than ambient's L4 ztunnel denial, producing 503s
  with `UF`/`URX` flags.
- **Telemetry signature**: `istio_requests_total{response_code="503",
  response_flags=~"UF|URX"}` - identical signature to
  `mtls-policy-conflict.yaml`.
- **Signal draft (PromQL)**: identical to `mtls-policy-conflict.yaml`'s
  `signal.promql`.
- **Inject sketch**: identical to the existing catalog entry - STRICT
  `PeerAuthentication` on `demo` (non-ambient/sidecar install) plus a
  plaintext curl pod without sidecar injection calling `payments:9090`.
- **Triage signatures**: identical to the existing catalog entry.
- **Detectable deterministically?**: yes (already implemented).
- **Overlaps existing catalog?**: **yes - full duplicate of
  `mtls-policy-conflict.yaml`.** That entry's description already explicitly
  covers "some client outside the mesh (or without a sidecar/ztunnel)."
  Kept in this document only to make the L7 (sidecar)-vs-L4 (ambient)
  contrast explicit for the taxonomy; do **not** add this as a new catalog
  entry.
- **Sources**: https://github.com/istio/istio/issues/41010 ,
  https://github.com/istio/istio/issues/29118 ,
  /Users/kadirhan/meshmedic/catalog/mtls-policy-conflict.yaml (existing
  entry being duplicated)

## peerauth-portlevel-override-conflict

- **Mechanism**: A `PeerAuthentication` sets `portLevelMtls` on one workload
  port (e.g. `PERMISSIVE` on a metrics port so an unmeshed scraper can reach
  it) but the port number must match the workload's **container** port, not
  the Kubernetes Service port - a common mismatch means the override
  silently doesn't apply and the port stays at the namespace/mesh STRICT
  default, still rejecting the caller it was meant to exempt. The inverse
  bug also occurs: a forgotten `portLevelMtls: PERMISSIVE` override left on
  one port after a workload's STRICT rollout is a silent plaintext hole with
  no denial telemetry at all.
- **Telemetry signature**: override-doesn't-apply case: same
  `UF`/`URX` 503 (sidecar) or `DENY` (ambient) signature as the two existing
  mTLS entries, scoped to one port. Forgotten-override case: no
  denial signal - only a `connection_security_policy` split
  (`mutual_tls` vs `none`) visible per-port in
  `istio_tcp_connections_opened_total`, mirroring the ambient doc's
  `connection-security-breakdown` evidence query but grouped by destination
  port instead of by service.
- **Signal draft (PromQL)**: `sum by (connection_security_policy) (rate(istio_tcp_connections_opened_total{destination_service_name="payments", destination_service_namespace="demo"}[5m]))` - the payments testbed has only one container port (9090), so reproducing the multi-port mismatch needs a second port added to `payments-v1`; noted as a testbed gap.
- **Inject sketch**: `kubectl apply` a `PeerAuthentication` in `demo` with
  `mtls.mode: STRICT` and `portLevelMtls: {9090: {mode: PERMISSIVE}}` where
  `9090` is written as the Service port while the workload's actual
  container port differs (or add a second container port to `payments-v1`
  to demonstrate the override applying to only one port correctly).
- **Triage signatures**: `kubectl get peerauthentication -n demo -o yaml`
  diffed against `kubectl get pod payments-v1 -o
  jsonpath='{.spec.containers[0].ports}'`; `istioctl experimental describe
  pod payments-v1` for the effective per-port mTLS mode (noting this
  describe output has itself been reported incomplete, see sources).
- **Detectable deterministically?**: partial - the override-doesn't-apply
  failure mode reduces to the existing UF/URX or DENY signal already
  covered by the two mTLS entries, scoped to one port; the
  forgotten-PERMISSIVE-hole failure mode has no denial telemetry at all and
  needs object evidence (the PeerAuthentication vs. actual container ports)
  to catch.
- **Overlaps existing catalog?**: extends `mtls-policy-conflict` /
  `mtls-policy-conflict-ambient` (same handshake mechanics) but the
  triggering config bug is a scoping/port-mapping error, not a wholesale
  STRICT rollout - distinct enough to warrant its own entry.
- **Sources**: https://github.com/istio/istio/issues/27994 ,
  https://github.com/istio/istio/issues/49098 ,
  https://github.com/istio/istio/issues/35871 ,
  https://github.com/istio/istio/issues/49802 ,
  https://istio.io/latest/docs/reference/config/security/peer_authentication/

## custom-authz-extauthz-outage-coupling

- **Mechanism**: A `CUSTOM` `AuthorizationPolicy` delegates every allow/deny
  decision to an external authorizer (`ext_authz` HTTP/gRPC provider). If
  that provider pod restarts, scales, moves namespace, or times out, Envoy's
  `ext_authz` filter (depending on `failure_mode_allow`) either fails open
  (silently stops authorizing - a security gap) or fails closed (denies
  everything through the workload), even though the destination workload
  itself is completely healthy - coupling app availability to an unrelated
  service's uptime.
- **Telemetry signature**: `istio_requests_total{response_code="403",
  response_flags="UAEX"}` - `UAEX` is Envoy's documented flag for
  ext_authz-service denials, distinct from the `"-"` flag on
  AuthorizationPolicy/app 403s. Caveat: `UAEX` has its own history of not
  being reliably set across Envoy versions (see envoyproxy sources below),
  so its absence does not prove absence of an ext-authz-caused 403.
- **Signal draft (PromQL)**: `sum(rate(istio_requests_total{destination_service_name="payments", destination_service_namespace="demo", response_code="403", response_flags="UAEX"}[2m])) > 0` - cross-check against total `response_code="403"` to catch the UAEX-not-set case.
- **Inject sketch**: apply a `CUSTOM` `AuthorizationPolicy` on `payments`
  pointing at an `extensionProviders` ext-authz Deployment/Service in
  `demo`, then `kubectl scale deploy/<ext-authz-name> --replicas=0` (or
  block it with a `NetworkPolicy`) - every `payments` call starts failing
  regardless of workload health.
- **Triage signatures**: `kubectl get deployment <ext-authz-name> -n demo`
  (replica count 0 correlating with 403 onset); istio-proxy access log
  `ext_authz_error` / `ext_authz_denied`; the `MeshConfig`
  `extensionProviders` block's `failOpen` setting.
- **Detectable deterministically?**: partial - `UAEX`-tagged 403s are a
  strong signal when the flag is reliably set, but known Envoy-version
  flakiness in setting `UAEX` means this can silently degrade to
  indistinguishable `"-"`-flagged 403s, requiring object evidence (ext-authz
  Deployment health) to close the loop.
- **Overlaps existing catalog?**: new.
- **Sources**: https://github.com/istio/istio/issues/41023 ,
  https://github.com/istio/istio/issues/46951 ,
  https://github.com/istio/istio/issues/38451 ,
  https://github.com/istio/istio/issues/48983 ,
  https://github.com/envoyproxy/envoy/issues/16723 ,
  https://github.com/envoyproxy/envoy/issues/18964 ,
  https://istio.io/latest/docs/tasks/security/authorization/authz-custom/

## workload-cert-ca-ttl-expiry

- **Mechanism**: A workload certificate's validity window - or the
  intermediate/root CA that signed it - expires. Either istiod's cert
  provider issues a longer workload-cert TTL than its signing intermediate
  has left, or an external cert-manager/custom CA root rotates while
  istiod/pilot-agent is down and the agent can't regenerate before the old
  cert lapses. Every mTLS handshake for the affected workload (or
  mesh-wide, if it's the root) starts failing certificate verification  - 
  independent of any AuthorizationPolicy or PeerAuthentication content.
- **Telemetry signature**: `istio_requests_total{response_code="503",
  response_flags=~"UF|URX"}` - the exact same request-layer symptom as
  `mtls-policy-conflict.yaml`. There is no dedicated Prometheus series for
  "certificate expired" found in the sources below; this class is
  distinguished from a real PeerAuthentication rollout only by object/log
  evidence (cert `notAfter`, no PeerAuthentication diff in the timeline).
- **Signal draft (PromQL)**: same query shape as
  `mtls-policy-conflict.yaml`'s `signal.promql`, scoped to the affected
  workload - cannot be told apart from a STRICT-mTLS rollout by PromQL
  alone.
- **Inject sketch**: not cleanly reproducible on the payments testbed
  without forcing a short `--workload-cert-ttl` on istiod and waiting out
  the window, or swapping the `cacerts` root mid-flight - out of scope for
  a manifest-only `inject.sh`. The closest analog is rotating the
  `istio-ca-secret` while pilot-agent is between renewal cycles.
- **Triage signatures**: `istioctl proxy-config secret <pod>` +
  `openssl x509 -enddate` on the delivered cert; istiod logs grep
  `certificate has expired`; the absence of any AuthorizationPolicy/
  PeerAuthentication object change in the timeline is itself the
  discriminator versus a real policy-driven mTLS conflict.
- **Detectable deterministically?**: partial-to-no - the traffic-metric
  signature is indistinguishable from `mtls-policy-conflict.yaml` (identical
  PromQL), so on metrics alone this is a "no"; it only becomes detectable by
  the *absence* of a corresponding policy-object change plus explicit
  cert-expiry object/log evidence, a materially different investigation
  path from the existing entry.
- **Overlaps existing catalog?**: extends `mtls-policy-conflict.yaml` at the
  traffic-metric layer (identical 503 UF/URX signature, would double-fire
  the same alert) but is a genuinely distinct root cause (cert lifecycle vs
  policy authoring) - worth flagging separately for triage-signature
  purposes even though it shouldn't get its own alerting rule.
- **Sources**: https://github.com/istio/istio/issues/18990 ,
  https://github.com/istio/istio/issues/46494 ,
  https://github.com/istio/istio/issues/13125

## multicluster-trust-domain-mismatch

- **Mechanism**: In a multi-cluster or multi-trust-domain mesh, workloads
  issued certs under different SPIFFE trust domains (or separate root CAs
  not cross-signed/federated) fail mTLS certificate verification when
  calling across clusters - `CERTIFICATE_VERIFY_FAILED` - even though both
  sides individually have valid STRICT mTLS and correct
  AuthorizationPolicies. The fix is trust-domain alignment or root
  federation, not a policy change.
- **Telemetry signature**: the same request-layer 503 UF/URX (sidecar) or
  `istio_tcp_connections_closed_total{response_flags="DENY"}` (ambient)
  signature as the existing mTLS entries, but scoped to only the
  cross-cluster caller - same-cluster traffic to the same workload stays
  healthy. The discriminator is *which callers* fail, not the metric shape.
- **Signal draft (PromQL)**: same shape as the two existing entries, ideally
  grouped by a cluster/network label - not confirmed present on
  `istio_requests_total`'s default label set in this benchmark's telemetry,
  flagged as unverified rather than assumed.
- **Inject sketch**: n/a - not reproducible on the single-node kind payments
  testbed in `payments.yaml` at all. Requires a second kind cluster with its
  own root CA and a cross-cluster Service export. Included here purely for
  taxonomy completeness.
- **Triage signatures**: `kubectl get secret cacerts -n istio-system` diffed
  across clusters; `istioctl proxy-config secret <pod>` to inspect the
  SPIFFE URI SAN's trust domain; envoy TLS error string
  `CERTIFICATE_VERIFY_FAILED`.
- **Detectable deterministically?**: no, on this testbed - the mechanism
  requires a topology (multiple clusters/trust domains) the payments
  testbed doesn't have. Documented as a gap, not a validated candidate.
- **Overlaps existing catalog?**: extends `mtls-policy-conflict-ambient` /
  `mtls-policy-conflict` conceptually (same handshake-failure family), but
  the trigger is identity federation, not PeerAuthentication mode - new for
  the taxonomy, not implementable on the current testbed.
- **Sources**: https://github.com/istio/istio/issues/37096 ,
  https://github.com/istio/istio/issues/39204 ,
  https://github.com/istio/istio/issues/31480
