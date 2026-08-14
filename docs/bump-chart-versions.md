# Bumping Chart Versions

This guide explains how to update HyperFleet component chart versions for deployments.

## Overview

HyperFleet component charts (API, Sentinel, Adapter) are published as OCI artifacts to Quay on every merge to main in their respective repos. This infrastructure repo consumes those charts from:

```
oci://quay.io/redhat-services-prod/hyperfleet-tenant/hyperfleet/
```

## Chart Version Variables

Environment variables control which charts are deployed and from where:

| Variable | Default | Purpose |
|----------|---------|---------|
| `CHART_REGISTRY` | `oci://quay.io/redhat-services-prod/hyperfleet-tenant/hyperfleet` | OCI registry base path |
| `API_CHART_VERSION` | `` (empty) | hyperfleet-api-chart version |
| `SENTINEL_CHART_VERSION` | `` (empty) | hyperfleet-sentinel-chart version |
| `ADAPTER_CHART_VERSION` | `` (empty) | hyperfleet-adapter-chart version |

These are defined in `helmfile/helmfile.yaml.gotmpl` and can be overridden via environment variables or `env.gcp`/`env.kind`.

**Chart Registry**: Override `CHART_REGISTRY` to pull charts from a fork or alternative registry:
```bash
# Use charts from a personal fork
CHART_REGISTRY=oci://quay.io/myusername/hyperfleet make install-hyperfleet
```

**Chart Versions**: 
- **Empty (default)**: Pulls the latest SemVer tag with Helm < 3.8. **Note**: Helm 3.8+ requires explicit versions; empty version will fail.
- **Pinned**: Set to a specific SemVer version (e.g., `0.3.1`) for production deployments or version testing.
## Listing Available Versions

### Via Quay UI

Browse to:
- https://quay.io/repository/redhat-services-prod/hyperfleet-tenant/hyperfleet/hyperfleet-api-chart?tab=tags
- https://quay.io/repository/redhat-services-prod/hyperfleet-tenant/hyperfleet/hyperfleet-sentinel-chart?tab=tags
- https://quay.io/repository/redhat-services-prod/hyperfleet-tenant/hyperfleet/hyperfleet-adapter-chart?tab=tags

### Via CLI

```bash
# List all tags for a chart
skopeo list-tags docker://quay.io/redhat-services-prod/hyperfleet-tenant/hyperfleet/hyperfleet-api-chart

# List recent tags (last 10)
skopeo list-tags docker://quay.io/redhat-services-prod/hyperfleet-tenant/hyperfleet/hyperfleet-api-chart | jq -r '.Tags[]' | sort -V | tail -10
```

## Bumping Versions

### Option 1: Override via CLI (temporary, one-time)

```bash
# Upgrade all three charts to 0.3.1
API_CHART_VERSION=0.3.1 \
SENTINEL_CHART_VERSION=0.3.1 \
ADAPTER_CHART_VERSION=0.3.1 \
make install-hyperfleet
```

### Option 2: Update env.gcp or env.kind (persistent for local dev)

Edit `env.gcp` or `env.kind`:

```bash
# Add or update these lines
export API_CHART_VERSION=0.3.1
export SENTINEL_CHART_VERSION=0.3.1
export ADAPTER_CHART_VERSION=0.3.1
```

Then deploy normally:

```bash
make install-hyperfleet
```

### Option 3: Update helmfile defaults (permanent, affects all users)

Edit `helmfile/helmfile.yaml.gotmpl`:

```yaml
values:
  - charts:
      api:
        version: {{ env "API_CHART_VERSION" | default "0.3.1" }}
      sentinel:
        version: {{ env "SENTINEL_CHART_VERSION" | default "0.3.1" }}
      adapter:
        version: {{ env "ADAPTER_CHART_VERSION" | default "0.3.1" }}
```

Commit and create a PR. After merge, all users get the new defaults.

## Upgrade Strategy

### Coordinated Release (recommended)

When all three component repos publish the same version:

```bash
# Single version bump for all charts
export CHART_VERSION=0.3.1
API_CHART_VERSION=$CHART_VERSION \
SENTINEL_CHART_VERSION=$CHART_VERSION \
ADAPTER_CHART_VERSION=$CHART_VERSION \
make install-hyperfleet
```

### Independent Versioning

When components have different versions (e.g., hotfix for API only):

```bash
# Bump only API chart
API_CHART_VERSION=0.3.1 make install-api

# Or bump all with different versions
API_CHART_VERSION=0.3.1 \
SENTINEL_CHART_VERSION=0.3.1 \
ADAPTER_CHART_VERSION=0.3.1 \
make install-hyperfleet
```

## Verification

After deploying with new chart versions:

```bash
# Export NAMESPACE explicitly based on your environment
export NAMESPACE=hyperfleet-local  # for kind
# export NAMESPACE=hyperfleet       # for gcp

# Check deployed chart versions
helm list -n "$NAMESPACE"

# Inspect a specific release
helm get values hyperfleet-api -n "$NAMESPACE"

# Verify chart metadata
helm get metadata hyperfleet-api -n "$NAMESPACE"
```

## Troubleshooting

### Chart version not found

```bash
Error: failed to download "oci://quay.io/redhat-services-prod/hyperfleet-tenant/hyperfleet/hyperfleet-api-chart" at version "0.3.1"
```

**Cause:** The requested chart version doesn't exist on Quay.

**Fix:** Verify the version exists using `skopeo list-tags` or the Quay UI. Check that the component repo's pipeline successfully published the chart.

### Permission denied pulling chart

```
Error: GET "https://quay.io/v2/...": response status code 401: unauthorized
```

**Cause:** Quay repository is private or you're not authenticated.

**Fix:** Charts should be public. If private, authenticate:

```bash
helm registry login quay.io -u <username>
```

### Helm says "improper constraint"

```
Error: improper constraint: 0.1.515_aff8821
```

**Cause:** Invalid version format. Helm expects SemVer (0.3.1), not commit-suffixed tags (0.1.515_aff8821).

**Fix:** Use the SemVer tag (0.3.1), not build metadata tags.

## Rollback

### Redeploy a Previous Chart Version

To deploy a previous chart version (not a Helm revision rollback):

```bash
# Redeploy API with chart version 0.3.0
API_CHART_VERSION=0.3.0 make install-api
```

This pulls chart version `0.3.0` from the registry and deploys it as a new Helm revision.

### Rollback to a Previous Helm Revision

To undo a deployment and restore a previous Helm release state:

```bash
# Export NAMESPACE explicitly based on your environment
export NAMESPACE=hyperfleet-local  # for kind
# export NAMESPACE=hyperfleet       # for gcp

# Check release history
helm history hyperfleet-api -n "$NAMESPACE"

# Rollback to a specific revision (e.g., revision 3)
helm rollback hyperfleet-api 3 -n "$NAMESPACE"
```

This restores the exact state of revision 3, including its chart version and values.

## Related

- Chart publishing pipeline: See `.tekton/` in component repos (hyperfleet-api, hyperfleet-sentinel, hyperfleet-adapter)
- Chart source: `charts/` directory in each component repo
- Epic: HYPERFLEET-831 (Helm OCI Distribution)
