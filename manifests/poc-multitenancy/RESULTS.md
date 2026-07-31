# Multi-Tenancy POC v2 Results

Run date: 2026-07-31. Full HyperFleet pipeline (API, 2 Sentinels, 3 adapters)
in kind behind Envoy + Authorino with tenant enforcement enabled. All traffic,
human and machine, authenticates at the gateway.

## Verdict

Both suites fully green on a clean cluster:

| Suite | Result |
|---|---|
| `scripts/test-multi-tenancy.sh` (onprem model, 16 tests) | 19/19 checks PASS |
| `scripts/test-model-swap.sh` (oracle model, 4 tests) | 4/4 checks PASS |

The lifecycle test is the headline: a tenant-created cluster reached
`Reconciled=True` with Sentinel polling and adapters writing status through
Envoy, authenticated by Kubernetes TokenReview as system identities. Tenant
isolation held before, during, and after the system writes.

## What was proven

1. Gateway authn: no token 401, missing required claim 403, forged
   `X-Tenant-*` / `X-HyperFleet-System` headers stripped before ext_authz
   (HCM early header mutation, not route-level removal).
2. Isolation: two tenants each see only their own resources in lists (with
   correct totals) and get 404, not 403, on cross-tenant point reads,
   deletes, and patches. No existence leak.
3. Tenancy map: server-populated from gateway identity on create, visible
   read-only in responses, body-supplied tenancy ignored on POST, rejected
   with 400 on PATCH, label patches leave it untouched.
4. Hierarchy via containment: an org-scoped token (no project claim) sees
   all the org's projects; a project-scoped token cannot see sibling
   projects.
5. Machine identity: Sentinel and adapter projected SA tokens (audience
   `hyperfleet-api`, the auth support both charts already shipped) validate
   via TokenReview, are marked system, and read/write across tenants. An
   unlisted in-cluster SA with a correct-audience token gets 403.
6. Per-deployment tenant models: switching from org+project to
   tenancy-OCID+compartment was one `make poc-switch-model TENANT_MODEL=oracle`
   plus an API re-render. Old-model tokens then 403, OCID tenants isolate
   on the new dimensions. Zero code changes in any component.

## Bugs found and fixed during the run

- The adapter chart values never honored `API_BASE_URL`, so adapters
  bypassed Envoy and hit the API service directly; their status writes were
  rejected 403 by tenant enforcement (the fail-closed default doing its
  job). Fixed in `helmfile/values/base-adapter.yaml.gotmpl`.
- Authorino renders a missing claim as the literal string `<nil>` in plain
  response headers. Org-scoped callers therefore carried
  `project: "<nil>"` in their filter and matched nothing (fail closed, but
  wrong). Optional tenant headers now have `when` conditions so they are
  only emitted when the claim exists.
- Assorted pipeline robustness: operator-managed Authorino deployment
  readiness, podman image naming for the mock JWT server, TokenReview RBAC
  for the Authorino SA.

## Reproduce

```
make local-up-kind                              # cluster + images + maestro + baseline
make install-poc-gateway                        # authorino + envoy + mock IdP + authconfig
CHART_ORG=<fork> API_CHART_REF=poc/multitenancy-v2 \
  TENANT_ENFORCEMENT=true TENANT_MODEL=onprem JWT_AUTH_ENABLED=true \
  API_BASE_URL=http://envoy.hyperfleet-local.svc.cluster.local:8000 \
  make install-hyperfleet
kubectl -n hyperfleet-local port-forward svc/mock-jwt-server 8081:8080 &
kubectl -n hyperfleet-local port-forward svc/envoy 8080:8000 &
./scripts/test-multi-tenancy.sh
```

Model swap: `make poc-switch-model TENANT_MODEL=oracle`, re-run
`install-hyperfleet` with `TENANT_MODEL=oracle`, then
`./scripts/test-model-swap.sh`.

Branches: hyperfleet-api `poc/multitenancy-v2` (tenancy column, DAO scoping,
middleware), hyperfleet-api-spec `poc/multitenancy-v2` (read-only tenancy on
Resource), this repo `poc/multitenancy-v2`.
